# x18

A new Flutter project.

## Getting Started

| Item                                | Required?         | Why                            |
| ----------------------------------- | ----------------- | ------------------------------ |
| Android “INTERNET” permission       | ✅                 | Without it, UDP fails silently |
| Multicast allowed                   | 👍                | XR18 discovery uses it         |
| OSC packets in proper binary format | **MUST**          | Text messages are ignored      |
| Correct port                        | Usually **10024** | 10025 only in Edit mode        |
| Path formatting                     | MUST              | `/bus/1/mix/fader` etc         |
