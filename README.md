# Captive Portal Prank (Kali Linux)

A joke-only WiFi hotspot for a laptop you own. When a friend joins the open
network, their phone auto-detects a "captive portal" and pops up a joke page
instead of the internet: a fake *Connecting to WiFi...* bar that gets stuck at
97%, a fake speed test reading **6G: 0.0 Mbps**, and the punchline
*"Do you even think our college has 6G?"*

> **This is a prank, on your own hardware, for people who are in on the joke.**
> It shares **zero internet**, collects **zero credentials** (there is no login
> form at all), and writes nothing about visitors to disk. Don't run it on
> networks you don't own or against people who haven't agreed to be pranked.

## How it works

```
 join hotspot ─▶ hostapd (open WiFi, e.g. College_Free_WiFi)
                     │
                 dnsmasq DHCP + DNS
                     │  hands out 10.0.0.x
                     │  DHCP option 114 (RFC 8910) = http://10.0.0.1:8080/generate_204
                     │  every DNS name → 10.0.0.1
                     ▼
              iptables NAT: :80 and :443 from wlan → 10.0.0.1:8080
                     ▼
                server.py  →  pages/6g-joke.html  (from config.json)
```

- **Auto-popup**: Android/iOS/Chrome probe plain-HTTP URLs
  (`/generate_204`, `/hotspot-detect.html`...). dnsmasq's option 114 and the
  port-80 redirect mean those probes land on the joke page, which triggers the
  OS "sign in to network" sheet.
- **HTTPS sites just fail to load** — there is no fake certificate interception,
  and that's expected/fine. The portal detection always uses plain HTTP.
- **No internet is shared.** No forwarding, no uplink relay. Joined devices get
  the joke and nothing else.

## Prerequisites (Kali Linux)

| Package         | Why                                  |
|-----------------|--------------------------------------|
| `hostapd`       | broadcasts the open WiFi network     |
| `dnsmasq`       | DHCP + DNS + captive-portal option   |
| `iw`            | finds a WiFi card that supports AP   |
| `iptables`      | redirects web traffic to the portal  |
| `iproute2`      | configures the interface address     |
| `python3`       | runs the portal server               |
| `python3-qrcode`| prints the fallback QR code (optional)|

`setup.sh` installs anything missing via apt automatically. Your WiFi card
must support **AP mode** (most Intel/Atheros cards do; `iw list` shows it).
If the card is your only internet uplink, **the laptop itself goes offline**
while the prank runs — use ethernet, or a second USB WiFi adapter.

## Quick start

```bash
sudo ./setup.sh     # start the hotspot (prints IP, URL and a QR code)
sudo ./stop.sh      # stop everything and restore normal networking
```

At the end of `setup.sh` you get the SSID, the laptop's IP, the portal URL and
an ASCII QR code encoding `http://<ip>:8080` — scan it if a phone doesn't
auto-pop the portal.

## Configuration

### Change the SSID (or channel / country)

Edit the **USER SETTINGS** block at the top of `setup.sh`:

```bash
SSID="College_Free_WiFi"   # the network name people see
CHANNEL="6"                # WiFi channel
COUNTRY_CODE="US"          # regulatory domain — must match your country
SUBNET="10.0.0.1"          # this laptop's IP on the hotspot
```

You can also override one-off without editing:

```bash
IFACE=wlan1 SSID="Free_Exam_Results" sudo -E ./setup.sh
```

### Swap the joke page (no restart needed)

`config.json` is the single source of truth:

```json
{
  "active_page": "6g-joke.html",
  "port": 8080
}
```

`server.py` re-reads it **on every request**, so this takes effect for the
very next device that loads the portal:

1. Drop a new file into `pages/`, e.g. `pages/my-joke.html` (start from
   `pages/template.html` — it's a fully commented blank copy; edit only the
   `EDIT ME` text, never the layout code).
2. Change `config.json`: `"active_page": "my-joke.html"`.

Changing `port` requires restarting the server (`sudo ./stop.sh` then
`sudo ./setup.sh`), since it's bound at startup.

### Writing your own page

Copy `pages/template.html` → `pages/your-name.html` and edit the spots marked
`EDIT ME`: the `jokeLines` array (shown randomly by the *Try Again* button),
the opening `PUNCHLINE`, the fake status lines and the fake speed-test row.
Keep `<!-- VISIT_COUNTER_PLACEHOLDER -->` — that's where server.py injects
"You are visitor #N today". Rules: no external assets (there's no internet to
fetch them) and no login form that validates or stores anything.

## Files

| File / dir            | Purpose                                          |
|-----------------------|--------------------------------------------------|
| `setup.sh`            | one-shot start: hostapd + dnsmasq + iptables + server |
| `stop.sh`             | clean teardown + network restore                 |
| `server.py`           | stdlib HTTP server, serves the active page       |
| `config.json`         | `active_page` and `port`                         |
| `pages/6g-joke.html`  | the default joke page                            |
| `pages/template.html` | commented blank page for your own jokes          |
| `run/`                | generated configs, PIDs and logs (gitignored)    |

## Troubleshooting

- **No popup on the phone** — scan the printed QR code, or type
  `http://10.0.0.1:8080` manually. Some laptops need
  `rfkill unblock wifi`. Check `run/server.log`.
- **hostapd won't start** — card lacks AP mode, or the interface is busy:
  `sudo systemctl stop wpa_supplicant` / check `iw list`.
- **dnsmasq fails on port 53** — something else (systemd-resolved) holds it;
  the dnsmasq log is in `run/dnsmasq.log`.
- **HTTPS sites show errors** — normal and intended; only HTTP is served.
- **Everything looks stuck** — `sudo ./stop.sh`, then re-run `sudo ./setup.sh`.
  stop.sh is safe to run after a partial setup.

## Legal / ethical

Prank only on WiFi networks and hardware you own, with people who know it's a
joke. Jamming, credential harvesting or intercepting networks you don't own is
illegal pretty much everywhere — this project does none of those things and
must not be modified to do them.
