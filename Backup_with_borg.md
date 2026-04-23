jensweber@jwm-2871 ~ % borg list ssh://o70eiudk@o70eiudk.repo.borgbase.com/./repo
borg list ssh://o70eiudk@o70eiudk.repo.borgbase.com/./repo::lume-db-storage-2026-04-04T03-00-14 


borg extract  ssh://o70eiudk@o70eiudk.repo.borgbase.com/./repo::lume-db-storage-2026-04-04T03-00-14 tmp/lume-backup-tXqUy2/db_backup.sql.gz
find in ~/tmp/lume-backup-tXqUy2/db_backup.sql.gz

borg extract  ssh://o70eiudk@o70eiudk.repo.borgbase.com/./repo::lume-db-storage-2026-04-04T03-00-14 tmp/lume-backup-tXqUy2/storage.tar

iba23