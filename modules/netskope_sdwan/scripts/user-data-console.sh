#cloud-config
password: ${password}
chpasswd: { expire: False }
ssh_pwauth: ${ssh_password_auth ? "True" : "False"}
