# 01-Enums.ps1 - The outcomes LazyVM's steps report, as types rather than text.
# Loaded before the functions by LazyVM.psm1; not meant to be run on its own.

enum MaintenanceDecision {
    # Plenty of time left, or no evaluation countdown at all.
    None
    # Expiry is close and a rearm is available.
    Rearm
    # Expiry is close and no rearms are left.
    Rebuild
}

enum MaintenanceStep {
    # What Invoke-Maintenance leaves for its caller to do next.
    None
    Rearmed
    Rebuild
    Build
    Error
}

enum BuildOutcome {
    Complete
    # The host is restarting to finish turning on Hyper-V; the resume task carries on.
    RestartPending
}

enum RemovalOutcome {
    Removed
    # Something could not be deleted; the log lists it.
    Incomplete
}

enum OSDiskAction {
    # C: already uses the whole disk.
    None
    # There is space after C: to grow into.
    Expand
    # Something other than a recovery partition sits after C:.
    Blocked
}
