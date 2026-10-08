# SDR Server Stack

Simple, dependency-light shell scripts to run `rtl_tcp` servers for one or more
RTL-SDR dongles on a single host. It:

1. **Inventories** every attached RTL-SDR dongle.
2. **Detects which dongles are in use** (claimed by another process such as an
   ADS-B feeder, or by the kernel DVB driver) without needing root.
3. Lets you **start**, **monitor**, and **stop** one `rtl_tcp` server per dongle.

## Requirements

- `rtl_tcp` and `rtl_test` (from `rtl-sdr`)
- `ss` (from `iproute2`), `bash`
- Linux, with the dongles on the USB bus

## Installation

There are no build steps — the scripts are plain `bash`. Clone the repository
and run the CLI directly:

```sh
# clone this repository, then:
cd sdr-server-stack
./sdr list    # confirm your dongles are detected
./sdr init    # generate sdr.conf
```

Optionally add `sdr` to your `PATH`:

```sh
sudo ln -s "$PWD/sdr" /usr/local/bin/sdr
```

## Files

```
sdr                       main CLI
lib/sdr-lib.sh            shared helpers (sourced)
sdr.conf.example          example configuration (copy to sdr.conf)
systemd/sdr-rtl-tcp@.service  optional systemd unit template
```

## Quick start

```sh
# 1. See what dongles are attached and whether they're free or in use
./sdr list

# 2. Auto-generate a config from the attached free dongles, then edit if needed
./sdr init
#    (alternative: cp sdr.conf.example sdr.conf and edit it by hand)

# 3. Start it
./sdr start radio

# 4. Check status / follow the log
./sdr status
./sdr monitor radio     # Ctrl-C to stop following

# 5. Stop it
./sdr stop radio
```

## Commands

| Command                  | Description                                        |
|--------------------------|----------------------------------------------------|
| `sdr list` / `ls`        | List physical dongles and their free/in-use state   |
| `sdr status` / `st`      | Show configured servers and running state          |
| `sdr init` / `setup`     | Auto-generate `sdr.conf` from attached free dongles |
| `sdr start <name|all>`   | Start `rtl_tcp` for a server (or all)               |
| `sdr stop <name|all>`    | Stop a server (or all)                              |
| `sdr restart <name|all>` | Stop then start                                     |
| `sdr logs <name>`        | Show recent log output                              |
| `sdr monitor <name>`     | Follow a server's log                               |
| `sdr run <name>`         | Run a server in the foreground (used by systemd)    |
| `sdr help`               | Help                                                |

## Configuration

`sdr.conf` is shell-sourceable. Global defaults:

- `LISTEN_ADDRESS` — bind address (`0.0.0.0` = all).
- `DEFAULT_SAMPLE_RATE`, `DEFAULT_GAIN` — applied unless overridden per server.
- `SERVERS` — space-separated list of server names to manage.

Per server, define `SDR_<name>_SERIAL` (required), `SDR_<name>_PORT` (required),
and optional `GAIN`, `FREQUENCY`, `SAMPLE_RATE`, `PPM`, `BIAS_TEE`,
`DIRECT_SAMPLING`, `EXTRA_ARGS`.

`sdr init` writes a ready-to-use `sdr.conf`: it creates one server per **free**
dongle (skipping any already in use), names each server after its
`/dev/rtl_sdr_<name>` symlink (falling back to `sdr0`, `sdr1`, …), and assigns
ports `1234`, `1235`, …. It refuses to overwrite an existing file unless you pass
`--force`; to write elsewhere, give a path: `sdr init --force /etc/sdr-server/sdr.conf`.

## How "in use" is detected

When a program (rtl_tcp, readsb, dump1090, etc.) claims an RTL-SDR via libusb,
the device's USB interface becomes bound to the `usbfs` driver. A free dongle
has no interface driver bound. The scripts read this from `/sys/bus/usb/devices`
and also scan `/proc/*/cmdline` to name the process holding a device — no root
required.

`start` refuses to launch if the target dongle is already claimed, if it is
held by the kernel DVB driver (needs `unbind`), or if its TCP port is taken.

## Runtime files

- PID files: `/run/sdr-server/<name>.pid` (root) or
  `${XDG_RUNTIME_DIR}/sdr-server/<name>.pid` (non-root).
- Logs: `/var/log/sdr-server/<name>.log` (root) or
  `~/.local/state/sdr-server/<name>.log` (non-root).

Override with `SDR_PID_DIR` / `SDR_LOG_DIR`, or point `SDR_CONF` at a different
config file.

## Running under systemd

See `systemd/sdr-rtl-tcp@.service`. Install and enable, e.g.:

```sh
sudo cp systemd/sdr-rtl-tcp@.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sdr-rtl-tcp@radio.service
```

## USB permissions

If you run `sdr` as a non-root user you may need udev rules granting access to
the RTL-SDR devices. A common setup is to add your user to the `plugdev` group
and set `GROUP="plugdev", MODE="0660"` on the `0bda:2838` devices.

## License

[MIT](LICENSE)
