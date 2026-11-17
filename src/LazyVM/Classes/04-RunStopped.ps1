# 04-RunStopped.ps1 - The error a run stops with when Stop-LazyVMBuild asks it to (#426).
# Loaded before the functions by LazyVM.psm1; not meant to be run on its own.
#
# A type of its own, so the code that carries on after a failure (the
# isolated steps, the guest-script retry) can tell a stop from a failure and
# let it through, and Invoke-CommandRun records the run as Stopped. An
# OperationCanceledException, so the app sees a cancellation.

class VMRunStoppedException : System.OperationCanceledException {
    VMRunStoppedException([string]$message) : base($message) {}
}
