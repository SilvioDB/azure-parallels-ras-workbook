# Replacing Parallels RAS Reporting Services

This project aims to replace the local Parallels RAS Reporting stack with Azure Monitor,
Log Analytics and Azure Workbooks.

Parallels RAS Reporting normally depends on:

- Microsoft SQL Server
- SQL Server Reporting Services
- Parallels RAS Reporting
- the RAS Reporting database schema

The Azure-native replacement keeps the reporting experience in the Workbook and stores
reporting data in Log Analytics tables.

## Current delivery

The first replacement step is the Workbook **Reports** tab. It behaves as a lightweight
report runner: choose a report type, adjust the filters, and show only the selected
report. It uses data that is collected by the current deployment:

| View | Status | Source |
| --- | --- | --- |
| Session activity trend | Available | `RASSessionHistory_CL` |
| Top users by observed sessions | Available | `RASSessionHistory_CL` |
| Published resource usage | Best effort | `RASSessionHistory_CL.PublishedResource` |
| Session activity detail | Available with inferred end timing | `RASSessionHistory_CL` |
| Logon/logoff/disconnect/reconnect trend | Available | `Event` |
| Disconnect/reconnect event detail | Available | `Event` |
| Server health reports | Available in Performance tab | `Perf`, `RASServer_CL` |

Available report-runner modes:

- Session activity
- User sessions
- Host sessions
- Published resources
- Disconnects

## Important precision boundaries

`RASSession_CL` is a periodic snapshot of active RAS sessions. `RASSessionHistory_CL`
adds a durable event layer on top of that snapshot by comparing each collector run with
the previous one. This is closer to the local RAS Reporting experience, but it is still
not the same as the local RAS Reporting database tables.

The current Workbook can provide:

- first and last time a session was observed;
- observed session duration;
- number of observed sessions per user, host and published resource;
- start, state-change and inferred-end session events;
- disconnect/reconnect activity from Windows Terminal Services events.

The current Workbook cannot yet provide exact equivalents for:

- `ApplicationConnections.Started`;
- `ApplicationConnections.Ended`;
- `ApplicationConnections.PID`;
- exact application launch count when multiple applications run in the same session;
- exact active, idle and disconnected duration from RAS Reporting tables;
- UX Evaluator, latency, bandwidth and connection quality history.

## Collector tables

`RASSessionHistory_CL` is implemented. Additional report-grade tables are still planned.

| Table | Purpose |
| --- | --- |
| `RASSessionHistory_CL` | Implemented: session start, state change, last seen and inferred end events |
| `RASConnectionEvent_CL` | Logon, logoff, disconnect, reconnect and disconnect reason events |
| `RASApplicationUsage_CL` | Published resource or application usage events |
| `RASDevice_CL` | Client/device inventory observed through sessions |
| `RASUserExperience_CL` | UX, latency, bandwidth and connection quality if exposed by RAS APIs/counters |

## Collector approach

The collector keeps a local state file on the Connection Broker host and compares it with
the current `Get-RASRDSession -Source All` result on every run.

Suggested event model:

| Condition | Event |
| --- | --- |
| Session appears for the first time | `Started` |
| Session remains present | `Observed` |
| Session state changes | `StateChanged` |
| Session disappears from the snapshot | `EndedInferred` |
| Terminal Services event 24 is collected | `Disconnected` |
| Terminal Services event 25 is collected | `Reconnected` |
| Terminal Services event 40 is collected | `DisconnectReason` |

The state file should contain only technical correlation fields and last-seen metadata:

- normalized computer name;
- session id;
- logon time;
- username;
- client name and IP;
- session state;
- published resource;
- first seen and last seen timestamps.

## Application usage investigation

The official RAS Reporting database exposes `ApplicationConnections`, but the current
collector does not receive equivalent fields.

Before adding process-level collection, test the RAS PowerShell object model on a live farm
for nested session application objects such as `RDSHostSessionApp` or
`RDSHostSysInfoSessionApp`.

If the RAS API exposes application name, PID, start and end timestamps, map them directly
to `RASApplicationUsage_CL`. If it does not, keep the Workbook label as **Published
resource usage** and avoid presenting it as exact application launch history.

## Workbook design

The Reports tab should remain report-like:

- a single report picker at the top;
- visible filters for period, user, server and published resource;
- compact KPI tiles at the top;
- trend charts immediately below;
- exportable tables for operational reporting;
- no decorative sections;
- clear titles that distinguish exact data from sampled or inferred data.

The Reports tab now uses event-backed queries for session activity without changing the
user workflow.
