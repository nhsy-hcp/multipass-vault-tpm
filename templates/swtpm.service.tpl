# Software TPM 2.0, one systemd instance per simulated machine.
#
# REFERENCE COPY. Templates live on the host and are never transferred into the
# VM, so the authoritative content is the heredoc in scripts/10_tpm_unit.sh.
# Keep the two in sync.
#
# Installed as /etc/systemd/system/swtpm@.service. %i is the instance name
# (`device` or `attacker`) and selects both the state directory and the
# per-instance port file — two TPMs with independent storage seeds is what
# makes the Part 8.1 stolen-key demo meaningful.
#
# ${SWTPM_PORT} / ${SWTPM_CTRL_PORT} are resolved by systemd from the
# EnvironmentFile, not by the renderer.

[Unit]
Description=Software TPM 2.0 (%i)
Documentation=man:swtpm(8)
After=network.target

[Service]
Type=simple
User=${LAB_USER}
Group=${LAB_USER}
EnvironmentFile=/etc/swtpm-lab/%i.env
ExecStart=/usr/bin/swtpm socket --tpm2 --tpmstate dir=/var/lib/swtpm-lab/%i --server type=tcp,port=${SWTPM_PORT} --ctrl type=tcp,port=${SWTPM_CTRL_PORT} --flags not-need-init,startup-clear
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
