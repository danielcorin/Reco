# Security policy

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting for this repository. If private reporting is not enabled yet, contact the repository owner privately and do not include exploit details in a public issue.

Include the affected revision, macOS version, reproduction steps, impact, and any suggested mitigation.

## Security boundaries

Reco is deliberately not sandboxed. It requires microphone access to record, Input Monitoring to observe the global shortcut, and Accessibility access to paste text into another app. Review changes involving these permissions, temporary audio files, model downloads, global event taps, clipboard access, and synthesized keyboard events with particular care.

Only the latest release is expected to receive security fixes.
