  #cloud-config
%{ if netskope_gw_default_password != "" ~}
  password: ${netskope_gw_default_password}
%{ endif ~}
  infiot:
    uri: ${netskope_tenant_url}
    token: ${netskope_gw_activation_key}
  write_files:
  - content: |
        {
          "frrCmdSets": [
            {
              "frrCmds": [
                "conf t",
                "ip community-list standard HA_COMMUNITY permit 47474:47474"
              ]
            },
            {
              "frrCmds": [
                "conf t",
                "ip prefix-list default seq 5 permit 0.0.0.0/0",
                "route-map advertise permit 10",
                "match ip address prefix-list default",
                "route-map set-med-peer permit 10",
                "set metric ${netskope_gw_bgp_metric}"
              ]
            },
            {
              "frrCmds": [
                "conf t",
                "router bgp ${netskope_gw_asn}",
                "neighbor ${transit_gw_peer_inside_ip1} disable-connected-check",
                "neighbor ${transit_gw_peer_inside_ip1} ebgp-multihop 2",
                "neighbor ${transit_gw_peer_inside_ip1} route-map set-med-peer out",
                "neighbor ${transit_gw_peer_inside_ip2} disable-connected-check",
                "neighbor ${transit_gw_peer_inside_ip2} ebgp-multihop 2",
                "neighbor ${transit_gw_peer_inside_ip2} route-map set-med-peer out"
              ]
            },
            {
              "frrCmds": [
                "conf t",
                "route-map To-Ctrlr-1 deny 5",
                "match ip address prefix-list default",
                "route-map To-Ctrlr-2 deny 5",
                "match ip address prefix-list default",
                "route-map To-Ctrlr-3 deny 5",
                "match ip address prefix-list default",
                "route-map To-Ctrlr-4 deny 5",
                "match ip address prefix-list default"
              ]
            },
            {
              "frrCmds": [
                "route-map From-Ctrlr-1 deny 6",
                "match community HA_COMMUNITY",
                "route-map From-Ctrlr-2 deny 6",
                "match community HA_COMMUNITY",
                "route-map From-Ctrlr-3 deny 6",
                "match community HA_COMMUNITY",
                "route-map To-Ctrlr-3 permit 10",
                "set community 47474:47474 additive",
                "route-map To-Ctrlr-2 permit 10",
                "set community 47474:47474 additive",
                "route-map To-Ctrlr-1 permit 10",
                "set community 47474:47474 additive",
                "route-map To-Ctrlr-4 permit 10",
                "set community 47474:47474 additive"
              ]
            }
          ]
        }
    path: /infroot/workdir/frrcmds-user.json
    permissions: '0644'
    owner: 'root:root'
