# Reporting a Bug

A useful HoRNDIS report needs evidence from the same session in which the problem occurred. Do not collect commands one by one or attach only a screenshot.

## Create the diagnostic report

1. Connect the Android device, enable USB tethering, and reproduce the problem.
2. Immediately open **HoRNDIS → Details → Save Diagnostic Report…**. You can instead run:

   ```sh
   horndis diagnostics ~/Desktop/HoRNDIS-Diagnostics.txt
   ```

3. Review the generated text file before sharing it.

The report is collected without administrator authorization and without uploading anything. It contains:

- HoRNDIS and macOS versions, Mac model, CPU architecture, and SIP state;
- non-identifying runtime fields, LaunchDaemon state, and installation/runtime file ownership and permissions;
- detected USB protocol, VID/PID, interface pairing, and support state, numbered as anonymous USB functions without device identity;
- the selected feth interface, link flags, MTU, and whether IPv4/IPv6 is configured, without address values;
- checks for an installed conflicting legacy HoRNDIS kernel extension; and
- up to the most recent 1,000 service-log lines, bounded to 512 KiB.

Account names, full names, host/device names, USB serial values and location IDs, MAC/IP addresses, hardware serial numbers, hardware UUIDs, packet contents, and credentials are not collected into the report. Users are represented only as `user`; detected devices are `device 1`, `device 2`, and so on. The unprivileged data process keeps the alias mapping only in memory, so the same device keeps its number across reconnects during that service run; the mapping is neither persisted nor sent to the root supervisor, and numbering restarts after the data process restarts. Older service-log lines created by a previous HoRNDIS version are sanitized while being copied. Service events and error text remain because they are necessary for diagnosis. Review the file before publishing it.

## Open the GitHub issue

Open [New bug report](https://github.com/noahhhi/HoRNDIS-Userspace/issues/new?template=bug_report.yml), or choose **HoRNDIS → Details → Report a Bug…** to create a fresh report and open the same form.

Describe the observed behavior, expected behavior, and exact reproduction steps. The GitHub form has a required file-upload field restricted to `.txt`, `.log`, or `.zip`; attach the newly generated `HoRNDIS-Diagnostics-*.txt`. Blank external issues are disabled. A screenshot or a raw `/var/log/horndis.log` alone does not replace the diagnostic report because it omits USB descriptors, DHCP state, permissions, and service status.

Generate a new report after reproducing each distinct problem. Do not reuse a report captured before the failure or from a different Mac/phone session.
