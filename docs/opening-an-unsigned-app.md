## If macOS says it cannot verify FishBrain

The first time you open FishBrain, macOS may show a warning instead of opening it. Take these steps once
and it opens normally from then on.

What you will see: on macOS 15 or later, a "Not Opened" dialog that says Apple could not verify FishBrain
is free of malware; on macOS 14, a dialog that says the developer cannot be verified, or, if you
Control-click and choose Open, "Are you sure you want to open it?". The wording varies by macOS version.

**macOS 15 Sequoia or later**

1. Open the DMG and drag **FishBrain** to **Applications**.
2. Open FishBrain from Applications. macOS says it was not opened. Click **Done**.
3. Open **System Settings > Privacy & Security** and scroll down to **Security**.
4. Next to "FishBrain was blocked to protect your Mac", click **Open Anyway** and confirm with your
   password or Touch ID.
5. Open FishBrain again and click **Open**.

**macOS 14 Sonoma**

Control-click (or right-click) **FishBrain** in Applications, choose **Open**, then click **Open** in the dialog.

**Check your download (optional)**

Every release lists the DMG's SHA-256 checksum. Compare it with:

```sh
shasum -a 256 ~/Downloads/FishBrain-unsigned.dmg
```

**Prefer not to trust an unsigned app?** Build it yourself from source; the README explains how.
