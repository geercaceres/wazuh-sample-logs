# 🧩 Wazuh Log Feeder Simulation Guide

This guide explains how to set up the **Wazuh Log Feeder** script, which simulates real integrations  
(AWS, GCP, Office 365, Azure, etc.) by continuously feeding JSON logs into the Wazuh agent.  
**If new logs entries will be added, make sure this are set in single line JSON format

---

## 1️⃣ Installation

### Step 1 – Download the script
```bash
sudo curl -fsSL -o /usr/local/bin/wz-logfeeder.sh \
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

## 2️⃣ How it works

- On the first run, the script:
1. Downloads the log list from GitHub.
2. Creates file-collected.log.
3. Adds a <localfile> block to /var/ossec/etc/ossec.conf
4. Restarts the Wazuh agent.

- Every 10 minutes, it appends new JSON lines (in random order) into the file, simulating constant log input.
Default paths:
```bash
/home/wazuh-user/sample-logs-list.txt
/var/ossec/logs/custom/file-collected.log
/var/log/wz-logfeeder.log
```
## 3️⃣ Wazuh Agent Configuration

The correct <localfile> entry should look like:

```bash
<localfile>
  <location>/var/ossec/logs/custom/file-collected.log</location>
  <log_format>json</log_format>
</localfile>
```

Validate configuration:
```bash
sudo /var/ossec/bin/wazuh-agentd -t -f
```
It must return: “Configuration OK”.


## 4️⃣ Verify it’s working
On the agent
```bash
sudo tail -n 30 /var/ossec/logs/ossec.log | grep -Ei 'file-collected|logcollector|json'
```
- On the Wazuh Dashboard
Go to Threat Hunting → Index: wazuh-alerts-*
You should see alerts such as:

1. Office 365: SharePoint events
2. AWS GuardDuty: PORT_PROBE
3. GCP emergency event...

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
