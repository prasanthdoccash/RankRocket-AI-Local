# Building & Installing the iOS App (TrollStore)

The iOS build happens **in the cloud on GitHub Actions** — no Mac needed. The
build produces an **unsigned/ad-hoc signed `.ipa`** that you install on your
iPhone with **TrollStore**.

## Requirements

- An **iPhone running iOS 16.4 or newer** (the LLM engine `llamadart` requires it)
- A TrollStore-compatible device (most iPhones up to iOS 17 with a suitable
  install method; see the [TrollStore docs](https://github.com/opa334/TrollStore))
- The GitHub repo: `techjarves/Uncensored-Local-AI-Multiplatform`

## Step 1 — Trigger the cloud build

1. Open the repo on GitHub → **Actions** tab.
2. Select **"Build iOS IPA (TrollStore)"** on the left.
3. Click **"Run workflow"** (top right).
4. Optional: type a **version tag** (e.g. `1.1.0`) if you want a draft GitHub
   Release created automatically. Leave it blank for a plain artifact.
5. Click the green **"Run workflow"** button and wait ~15 minutes.

## Step 2 — Download the .ipa

- When the run finishes (green check), open it and scroll to the **Artifacts**
  section.
- Download **`RankRocketAI-ios`**.
- Unzip it to get **`RankRocketAI.ipa`**.

> If you supplied a version tag, the same `.ipa` is also attached to a **draft
> Release** under **Releases → Drafts**.

## Step 3 — Install with TrollStore

1. Open **TrollStore** on your iPhone.
2. Tap the **+** button (top right) → **Install IPA File**.
3. Browse to `RankRocketAI.ipa` (use the **Files** app → Downloads).
4. Tap it to install. The app appears as **RankRocket AI**.

## Step 4 — First run

1. Open the app.
2. Go to the **Models** tab and download a model (the `INDIAN LAW` models are
   tuned for questions about the IPC, BNS/BNSS, CrPC, the Constitution of
   India, and Indian case law).
3. Tap **Load Model** and start chatting.

**License.** The app checks its license online on first launch
(`https://ai.rankrocket.online`). It works free for 30 days, then asks for a
license key from `rpfinser24@gmail.com`.

## Rebuilding

Any time you change the app code, just re-run the workflow (Step 1) and repeat
Steps 2–3. TrollStore keeps your app installed; reinstalling over it preserves
your downloaded models.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Build fails on GitHub | Open the failed run → logs. Common causes: CocoaPods version, or a stale Flutter lock. Retry once first. |
| TrollStore says "invalid IPA" | Make sure you extracted the `.zip` to get the actual `.ipa`, and that you're using the artifact from a **successful** run. |
| App crashes on load | Your iPhone must run **iOS 16.4+**. Model downloads need a working internet connection on first use. |