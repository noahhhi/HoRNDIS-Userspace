# Security policy

Please report vulnerabilities privately through GitHub's security-advisory feature rather than a public issue.

The daemon is intentionally root because BPF and persistent network configuration require elevated access. Treat USB descriptors, RNDIS lengths, and Ethernet frame lengths as untrusted. New code must validate every device-controlled offset before reading or allocating memory and must never invoke a shell with device-controlled data.

Supported releases receive security fixes on the latest minor version. The project does not require disabling System Integrity Protection or changing Startup Security Utility settings; instructions that require either are outside its supported threat model.
