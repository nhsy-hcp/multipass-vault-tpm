# Software TPM 2.0, one systemd instance per simulated machine.
#
# REFERENCE COPY. Templates live on the host and are never transferred into the
# VM, so the authoritative content is the heredoc in scripts/10_tpm_unit.sh.
# Keep the two in sync.
#
# Installed as /etc/systemd/system/swtpm@.service. %i is the instance name
# (`device` or `attacker`) and selects the state directory — two TPMs with
# independent storage seeds is what makes the Part 8.1 stolen-key demo
# meaningful.
#
# The TPM is served on a unix socket inside its state directory. tpm2-tools
# reach it via TPM2TOOLS_TCTI=swtpm:path=<sock> and the Vault CLI via
# -tpm-device-path=<sock>; the .ctrl socket is swtpm's control channel, which
# only the swtpm TCTI uses. A stale socket from an unclean stop would block the
# bind, hence the ExecStartPre.

[Unit]
Description=Software TPM 2.0 (%i)
Documentation=man:swtpm(8)

[Service]
Type=simple
User=${VM_USER}
Group=${VM_USER}
ExecStartPre=/bin/rm -f ${TPM_STATE_ROOT}/%i/swtpm.sock ${TPM_STATE_ROOT}/%i/swtpm.sock.ctrl
ExecStart=/usr/bin/swtpm socket --tpm2 --tpmstate dir=${TPM_STATE_ROOT}/%i --server type=unixio,path=${TPM_STATE_ROOT}/%i/swtpm.sock --ctrl type=unixio,path=${TPM_STATE_ROOT}/%i/swtpm.sock.ctrl --flags not-need-init,startup-clear
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
