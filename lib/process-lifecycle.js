export const PROCESS_TERMINATION_GRACE_MS = 1500;

function processIsRunning(proc) {
  return proc && proc.exitCode === null && proc.signalCode == null;
}

export function signalProcessGroup(proc, signal, killImpl = process.kill) {
  if (!proc || !Number.isInteger(proc.pid) || proc.pid < 1) return false;
  try {
    killImpl(-proc.pid, signal);
    return true;
  } catch {
    try {
      return proc.kill(signal) !== false;
    } catch {
      return false;
    }
  }
}

export function terminateProcessGroup(proc, options = {}) {
  const killImpl = options.killImpl || process.kill;
  const graceMs = Number(options.graceMs ?? PROCESS_TERMINATION_GRACE_MS);
  if (!signalProcessGroup(proc, 'SIGTERM', killImpl)) return false;

  const timer = setTimeout(() => {
    if (processIsRunning(proc)) signalProcessGroup(proc, 'SIGKILL', killImpl);
  }, Number.isFinite(graceMs) && graceMs >= 0 ? graceMs : PROCESS_TERMINATION_GRACE_MS);
  const clear = () => clearTimeout(timer);
  proc.once?.('exit', clear);
  proc.once?.('error', clear);
  return true;
}
