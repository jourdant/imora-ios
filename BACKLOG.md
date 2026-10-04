# Backlog

## Backup preferences

- **Separate cellular rules for photos and videos.** Allow photos to sync over cellular while videos wait for Wi-Fi. Define how Live Photo motion components are treated; apply the choices to indexing/iCloud downloads, backlog uploads, recent captures, and recovery.
- **Suggest changing frequently overridden settings.** Track deliberate “Sync This Time” uses separately for cellular and low battery. After repeated overrides, offer a quiet, dismissible suggestion linking to Backup Settings to enable cellular backup or disable/adjust low-battery pausing. Define a minimum number of uses, time window, cooldown, and “Don’t Ask Again”; never change preferences automatically.

Pre-merge verification for the implemented controls lives in [the backup regression checklist](Tests/BackupRegression/README.md#backup-controls-pre-merge-device-checklist).

## Albums

- **Add pull-to-refresh to albums.** Let users pull down in an album’s contents to fetch the latest server state, including photos and videos another member has uploaded or added to a shared album, without leaving and reopening it.
  - Pull-to-refresh works for populated and empty albums and updates the grid and item count from the server.
  - Show a refresh indicator while fetching; repeated pulls must not create overlapping refreshes or duplicate items.
  - Keep existing items visible during refresh. If it fails, preserve the current contents, show a clear error, and allow retry.
  - Verify with two members: one adds an item while the other has the album open; a pull-to-refresh shows it exactly once and updates the count.
