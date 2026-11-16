/// Weight surfaces are hidden by the master supportive-mode switch or the
/// individual weight-nudge preference. A missing key keeps the default visible
/// behavior.
bool hidesWeight(Map<String, Object?> settings) =>
    settings['support'] == true || settings['hideWeightNudges'] == true;
