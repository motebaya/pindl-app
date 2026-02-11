/// Media type for filtering
enum MediaType { image, video }

/// Status of a job - strict state machine for submit->info->download flow
/// Phase A: idle
/// Phase B: fetchingInfo (submit phase - extracting metadata only)
/// Phase C: readyToDownload (info loaded, waiting for download confirmation)
/// Phase D: downloading
/// Phase E: completed / interrupted / failed
enum JobStatus {
  idle,           // Phase A: No operation in progress
  fetchingInfo,   // Phase B: Submit pressed - fetching/extracting info only
  readyToDownload,// Phase C: Info fetched, awaiting download confirmation
  downloading,    // Phase D: Download in progress
  paused,         // Download paused (can resume)
  completed,      // Phase E: All done successfully
  failed,         // Phase E: Operation failed
  cancelled,      // Phase E: User cancelled
}
