# Futur-Tech Bidirectional Osync-based SysVol replication 

Samba currently doesn't provide support for SysVol replication, using Osync we make a workaround.

> Original idea: https://wiki.samba.org/index.php/Bidirectional_Rsync/osync_based_SysVol_replication_workaround

This repository aims to **automatically** setup this replication.

There are a few assumptions to use this deploy script:
- You only have 2 Domain Controllers in your domain
- SysVol is located at `/var/lib/samba/sysvol` on both Domain Controllers

## Deploy Commands

Everything is executed by only a few basic deploy scripts. Just follow on screen instructions.

```bash
cd /usr/local/src
git clone https://github.com/Futur-Tech/futur-tech-osync-sysvol.git
cd futur-tech-osync-sysvol

./deploy.sh 
# Main deploy script

./deploy-update.sh -b main
# This script will automatically pull the latest version of the branch ("main" in the example) and relaunch itself if a new version is found. Then it will run deploy.sh. Also note that any additional arguments given to this script will be passed to the deploy.sh script.
```

You can test a synchronization with `/usr/local/bin/futur-tech-osync-sysvol/osync.sh /usr/local/src/futur-tech-osync-sysvol.conf --dry-run --verbose`