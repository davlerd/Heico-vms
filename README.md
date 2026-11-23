# AWS Cloud WAN + Palo Alto VM-Series + Netskope SD-WAN (template integrado)

Un único root module de Terraform que despliega, en AWS, los tres componentes sobre un mismo core network:

| Componente | Origen | Qué se despliega |
|---|---|---|
| **Palo Alto VM-Series** | `terraform-aws-swfw-modules` → `examples/combined_design` | Security VPC, GWLB + endpoints (east-west / outbound), **1 VM-Series sin autoscaling**, IAM |
| **Netskope SD-WAN GW** | `terraform-netskopebwan-aws` + template *netskope-greenfield-flexible* (consola) | **VPC propia**, 1 gateway (appliance único, sin HA), GRE + BGP hacia Cloud WAN; activación desde la consola de Netskope (o por API, opcional) |
| **AWS Cloud WAN** | `terraform-aws-cloudwan` | Global network, core network, política (segmentos, NFG, service insertion) |

```
                     ┌──────────────── AWS Cloud WAN core network (política en cloudwan.tf) ────────────────┐
                     │  segmento "workloads"   segmento "sdwan"            NFG "paloalto" (service insertion)│
                     └───────────▲───────────────────▲───────────────────────────────▲────────────────────────┘
                                 │ VPC attach        │ VPC attach + Connect (GRE/BGP)│ VPC attach (appliance mode)
                       Spokes (otras cuentas)   VPC SD-WAN 10.103.1.0/24        VPC Seguridad 10.103.0.0/24
                       DR / Lucix / IndiaSub    Netskope SD-WAN GW (ge1 WAN,    VM-Series + GWLB + endpoints
                                                ge2 LAN)  ── IGW                 (egress NAT en el firewall) ── IGW
```

* **Netskope y Palo Alto van en VPCs distintas.** Cada módulo crea su VPC y un *guardrail* (`netskope.tf`) falla el plan si algún rango (VPCs o CIDR GRE de Cloud WAN) se solapa o queda fuera de `address_space`.
* El **Transit Gateway del diseño original se sustituye por Cloud WAN**:
  * Security VPC → *VPC attachment* con `appliance_mode_support = true`, miembro del *network function group* `paloalto`.
  * VPC SD-WAN → *VPC attachment* (transporte) + *Connect attachment* GRE + *Connect peer(s)* BGP, en el segmento `sdwan`.
  * Tráfico **internet-bound** de los segmentos (`send-to`) y **east-west sdwan ↔ workloads** (`send-via`) pasan por el firewall.

## Direccionamiento (bloque asignado 10.103.0.0/16)

Las dos VPCs y el rango GRE de Cloud WAN salen del mismo bloque `10.103.0.0/16` (`address_space`); si algún rango queda fuera o se solapa, el plan falla.

| Rango | Uso | Detalle |
|---|---|---|
| `10.103.0.0/24` | VPC Palo Alto (seguridad) | AZ a en `10.103.0.0/25`, AZ b reservada en `10.103.0.128/25` |
| `10.103.1.0/24` | VPC Netskope SD-WAN | 1 appliance en `10.103.1.0/25`; el resto del /24 queda libre |
| `10.103.255.0/24` | Cloud WAN inside CIDR | extremos GRE del core network |
| `10.103.2.0/23` – `10.103.254.0/24` | libre | crecimiento (segunda región, más VPCs) |

Subnets de la VPC de seguridad (todas /28, AZ a): `mgmt` .0, `private` .16, `public` .32, `cloudwan_attach` .48, `gwlbe_outbound` .64, `gwlb` .80, `gwlbe_eastwest` .96 (último octeto de `10.103.0.x/28`).
Subnets de la VPC SD-WAN: `ge1` WAN `10.103.1.0/28`, `ge2` LAN `10.103.1.16/28`.

## Estructura

```
versions.tf / providers.tf        Providers (aws >= 6, netskopebwan 0.0.2, time)
variables.tf                      Variables del root
cloudwan.tf                       Política del core network + módulo Cloud WAN
paloalto.tf                       Combined design (VPC, subnets, rutas, GWLB, VM-Series) + adjuntos a Cloud WAN
netskope.tf                       Módulo Netskope + guardrails (solapamiento de CIDR, NFG, región)
outputs.tf
terraform.tfvars.example          Ejemplo completo (copiar a terraform.tfvars)
secrets.auto.tfvars.example       Secretos (copiar a secrets.auto.tfvars, no se versiona)
tests/plan.tftest.hcl             Test de plan con providers simulados
modules/pan/*                     Copia de los módulos PAN usados (MIT). vpc_route parcheado: next hop `core_network`
modules/cloudwan                  Copia reducida del módulo aws-ia/cloudwan (Apache-2.0): global/core network, política, RAM
modules/netskope_sdwan            Port del módulo Netskope (ver cambios abajo)
```

## Prerrequisitos

1. **Terraform ≥ 1.9** y credenciales AWS con permisos sobre EC2, ELB, IAM, Network Manager (Cloud WAN) y RAM.
2. **AWS Marketplace**: suscripción a la AMI de **VM-Series** (BYOL, `vmseries_product_code`) y a la AMI del **gateway Netskope**; el **ID de la AMI** (`netskope.instance.ami_id`) se toma de la consola de Netskope / Marketplace para la región.
3. **Netskope**: acceso a la consola para activar el gateway. Solo con `portal_automation = true` (flujo heredado por API) hacen falta además tenant ID, URL base y **API token REST** (`netskope_api_token`).
4. **Palo Alto** (igual que en el README del combined design): Panorama o SCM con device group / template stack, `sw_fw_license` (o PIN de SCM), *interface management profile* para los health checks del GWLB, e interfaces/subinterfaces `ethernet1/1.20` (outbound) y `ethernet1/1.30` (east-west), zonas y virtual router en la plantilla.
5. Key pair EC2 existente en la región.

## Uso

```powershell
Copy-Item terraform.tfvars.example terraform.tfvars        # ajustar los TODO
Copy-Item secrets.auto.tfvars.example secrets.auto.tfvars   # auth-key de Panorama, contraseña del gateway (y token Netskope solo con portal_automation)
terraform init
terraform plan
terraform apply
```

Orden que resuelve Terraform solo: core network + política → VPC de seguridad (adjunto NFG) y VPC SD-WAN (adjuntos + Connect peer) → instancia del gateway Netskope (y, solo con `portal_automation = true`, sus objetos en el portal).
La creación del core network y de la política tarda **varios minutos** (típicamente 10–30).

### Netskope: dos modos (`netskope.portal_automation`)

| Modo | Qué hace Terraform | Qué haces tú |
|---|---|---|
| `false` (por defecto) — **consola** | Solo la infraestructura AWS (VPC, subnets, ENIs con IP fija, EIP, instancia, adjuntos y Connect peer de Cloud WAN). Es el flujo del template *netskope-greenfield-flexible* descargado de la consola. | Activar y configurar el gateway desde la consola de Netskope, incluidos el túnel GRE y el vecino BGP, con los valores del output `netskope_cloudwan_connect_details` (IP GRE local/remota, inside CIDR, IP interna del gateway, vecinos BGP, ASN de Cloud WAN y del gateway). |
| `true` — **API (heredado)** | Además crea política, gateway, interfaces, rutas y BGP en el portal con el provider `netskopebwan` y arranca el gateway con el token de activación. | Ejecutar en el gateway el `infhostd config-gre …` del output `netskope_primary_gw_gre_config` y reiniciar los servicios. |

`portal_automation = true` es el flujo del módulo original (AMI `Infiot-Edge_*`); si lo usas, define `tenant_id`, `tenant_url` y `netskope_api_token`. Para acceder al gateway en modo consola: contraseña por cloud-init (`netskope_gateway_password`, y `ssh_password_auth = true` si quieres login SSH por contraseña) y tu IP en `ssh_allowed_cidrs` / `https_allowed_cidrs`; ambas vienen cerradas por defecto.

### Verificación sugerida

* Cloud WAN: adjuntos en estado `AVAILABLE`, Connect peer con BGP `UP`, y `aws networkmanager get-network-routes` mostrando `0.0.0.0/0` en los segmentos hacia el NFG.
* Palo Alto: VM-Series registrado en Panorama/SCM, target group del GWLB en `healthy`, tráfico visible en las subinterfaces `1.20` / `1.30`.

## Cambios respecto a los templates originales

**Palo Alto (`combined_design`)**: `tgws`/`tgw_attachments`/`panorama_attachment` → `cloudwan_attachments` (el next hop de las rutas es `core_network_attachment`, que usa el ARN del core network); sin NAT gateway (el firewall hace el NAT de salida); sin VMs/ALB/NLB de prueba; subnet group `tgw_attach` → `cloudwan_attach`; los secretos de bootstrap salen del tfvars a `bootstrap_secrets` (sensible); recurso IAM con `jsonencode`.

**Cloud WAN**: módulo reducido a global network + core network + política + RAM (se quitaron `central_vpcs` y Network Firewall, que descargaban módulos externos en `init`). La política se genera con `aws_networkmanager_core_network_policy_document`.

**Netskope**: los tres submódulos se fusionaron en `modules/netskope_sdwan`; TGW + TGW Connect → **Cloud WAN VPC attachment + Connect attachment + Connect peer**; los vecinos BGP y el ASN remoto salen del Connect peer; `aws_eip.vpc` → `domain = "vpc"` (el provider AWS ≥ 6 que exige Cloud WAN lo eliminó); SSH cerrado por defecto (`ssh_allowed_cidrs`) y SG privado limitado a rangos privados (antes `0.0.0.0/0`); `source_dest_check = false` en todas las ENI del gateway; contraseña opcional y sensible; se eliminaron el modo "VPC existente" y el cliente demo.

**Netskope — alineado con el template de la consola (`netskope-greenfield-flexible`)**: instancia `c5.xlarge` (antes `t3.medium`), disco raíz gp3 de 38 GB (cifrado), AMI por ID explícito (`ami_id`; la búsqueda por nombre queda como alternativa), IP privada fija opcional por interfaz (`private_ip`), y modo consola sin provider/API/token. No se adoptó del template: SSH y 443 abiertos a `0.0.0.0/0` (aquí van cerrados y se abren con `ssh_allowed_cidrs` / `https_allowed_cidrs`), contraseña en texto plano en el tfvars (aquí es una variable sensible), `ssh_pwauth` siempre activo (aquí es opcional) y el SG de la LAN sin ingress (aquí admite los rangos privados y el GRE de Cloud WAN). El template de la consola no incluye Cloud WAN, GRE ni BGP; esa parte sigue siendo la de este proyecto.

**Versiones**: el módulo Netskope original fija `aws ~> 4.30` y `time ~> 0.7.2` y `gwlb_endpoint_set` fija `time 0.11.1`; en el root se unifican en `aws >= 6, < 7` y `time >= 0.11.1`.

## Límites conocidos / a validar en laboratorio

* **Validado**: `terraform validate`, `terraform test` (plan con providers simulados) y render de la política con el provider real. **No se ha hecho `apply` contra AWS ni contra el tenant de Netskope**, y el modo consola no se ha comprobado contra la consola real: los pasos de activación y de GRE/BGP en ella dependen de la versión del gateway.
* Diseño de **1 AZ** con 1 firewall (sin alta disponibilidad). Para HA del firewall: duplicar los subnets en otra AZ y añadir la instancia `"02"`. Netskope va con **un solo appliance** (`ha_enabled = false`); el soporte de gateway secundario sigue en el módulo pero no se usa.
* Un solo *edge* (`var.region`). Para multi-región (p. ej. `us-west-2` + `ap-south-2`) hay que definir `cloudwan.edge_locations` y repetir el stack de seguridad/SD-WAN por región con providers `aws` con alias.
* El modelo *combined* inbound (GWLB endpoints en VPCs spoke) está soportado por el motor (`gwlb_endpoints` con `act_as_next_hop`, `subinterfaces.inbound`), pero el ejemplo no define spokes porque en la topología HEICO ningún entorno recibe tráfico entrante. Los spokes de otras cuentas se adjuntan al core network con el tag `segment = workloads` (RAM share vía `core_network.ram_share_principals` si hace falta).
* El *Connect attachment* se etiqueta (`segment = sdwan`) igual que su VPC attachment de transporte; confirmar en laboratorio que ambos quedan en el segmento esperado.

## Tests

```powershell
terraform test -var-file=terraform.tfvars.example
```

## Origen del código

* `modules/pan`: PaloAltoNetworks/terraform-aws-swfw-modules (MIT, ver `modules/pan/LICENSE`).
* `modules/cloudwan`: aws-ia/terraform-aws-cloudwan (Apache-2.0, ver `LICENSE` y `NOTICE.txt`).
* `modules/netskope_sdwan`: netskopeoss/terraform-netskopebwan-aws (© Infiot / Netskope) y template *netskope-greenfield-flexible* descargado de la consola de Netskope. Ninguno incluía archivo de licencia; revisar los términos antes de redistribuir.
