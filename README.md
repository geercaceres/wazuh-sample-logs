# 🧩 Wazuh Log Feeder Simulation Guide

This guide explains how to set up the **Wazuh Log Feeder** script, which simulates real integrations  
(AWS, GCP, Office 365, Azure, etc.) by continuously feeding both standard and JSON logs into the Wazuh agent.  
**If new logs entries will be added, make sure these are set in the corresponding file, depending on the format, file-collected.log or json-file-collected.log

---

## 1️⃣ Installation

### Step 1 – Download the script
```bash
sudo curl -A "Mozilla/5.0" -fsSL \
  -o /usr/local/bin/wz-logfeeder.sh \
  https://raw.githubusercontent.com/geercaceres/wazuh-sample-logs/main/wz-logfeeder.sh

sudo chmod +x /usr/local/bin/wz-logfeeder.sh

```

### Step 2 – Start the feeder in background
```bash
sudo /usr/local/bin/wz-logfeeder.sh start
```
Default behavior: appends 100 JSON logs every 10 minutes.
The service runs in background (no need to keep the terminal open).

Check status:
```bash
sudo /usr/local/bin/wz-logfeeder.sh status
```
Check logs:
```bash
tail -n 20 /var/log/wz-logfeeder.log
```


## 2️⃣ How it works

- On the first run, the script:
1. Downloads the two log lists from GitHub, one for JSON logs and another for standard logs.
2. Creates two file-collected.log, one for JSON and another for standard logs.
3. Adds two <localfile> block to /var/ossec/etc/ossec.conf
4. Restarts the Wazuh agent.

- Every 10 minutes, it appends new standard and JSON lines (in random order) into the files, simulating constant log input.
Default paths:
```bash
Standard logs:
/home/wazuh-user/sample-logs-list.txt
/home/wazuh-user/file-collected.log

JSON logs:
/home/wazuh-user/json-sample-logs-list.txt
/home/wazuh-user/json-file-collected.log

Service logs:
/var/log/wz-logfeeder.log
```
## 3️⃣ Wazuh Agent Configuration

The correct <localfile> entry should look like:

```bash
<localfile>
  <location>/home/wazuh-user/file-collected.log</location>
  <log_format>syslog</log_format>
</localfile>

<localfile>
  <location>/home/wazuh-user/json-file-collected.log</location>
  <log_format>json</log_format>
</localfile>

```

Validate configuration:

## 4️⃣ Verify it’s working
On the agent
```bash
sudo tail -n 100 /var/ossec/logs/ossec.log | grep 'Analyzing file:' | grep file-collected
```
- On the Wazuh Dashboard
Go to Threat Hunting → Index: wazuh-alerts-*
You should see alerts such as:

1. Office 365: SharePoint events
2. AWS GuardDuty: PORT_PROBE
3. GCP emergency event...
4. Fortigate: SSL fatal alert.

## 5️⃣ Adjusting parameters
You can change the feed speed easily:
```bash
sudo LINES_PER_TICK=300 SLEEP_SECONDS=300 /usr/local/bin/wz-logfeeder.sh start
```

## 6️⃣ Stop or restart
```bash
sudo /usr/local/bin/wz-logfeeder.sh stop
sudo /usr/local/bin/wz-logfeeder.sh start
```
