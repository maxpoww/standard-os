# /var/lib/standard-os/ — persistent state for the UPDATE subsystem.
# Lives in /var/lib (not /tmp) so error logs and history survive reboots.
# Owned by user max:users so the user-systemd update pipeline can write
# without escalation.
{ config, lib, ... }:
{
  systemd.tmpfiles.rules = [
    "d /var/lib/standard-os 0755 max users -"
  ];
}
