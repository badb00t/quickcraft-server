# Install Guide

## 1. Install Termux

Get it from [F-Droid](https://f-droid.org/packages/com.termux/) (recommended — the Play Store version is no longer updated).

## 2. First-time Termux setup

Open Termux and run:

```bash
pkg update -y && pkg upgrade -y
termux-setup-storage
```

Accept the storage permission popup on your phone when it appears.

## 3. Download and run the script

Replace the URL below with your script's **raw** GitHub link (open the file on GitHub → click **Raw** → copy the URL), then run:

```bash
curl -o https://raw.githubusercontent.com/badb00t/quickcraft-server/refs/heads/main/install_paper_server.sh
chmod +x install_paper_server.sh
bash install_paper_server.sh
```

That should be it.

## Next time

Once it's set up, just start the server with:

```bash
cd ~/paperserver && ./start.sh
```
