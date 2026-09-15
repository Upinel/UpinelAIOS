<!--
  Nova Upinel Chow, MSc, LLM, BBA, MENSA  ·  dev@upinel.com  ·  upinel.com
  Copyright (c) 2026 Nova Upinel Chow. All rights reserved.

  Upinel Personal Free License: free for personal use, and free for creators
  (YouTubers, KOLs) to make content with - just email dev@upinel.com to say so.
  Other commercial use needs written permission. Derivatives must credit the
  author. Covers this project's own code only. See LICENSE.

  "Make it work, make it right, make it fast - then measure it, because
   the third one is only a claim until the numbers agree."
-->
<h1 align="center">UpinelAIOS-MLX — moved</h1>

<p align="center">
  <b>This project now lives in <a href="https://github.com/Upinel/UpinelAIOS">UpinelAIOS</a>.</b><br>
  The MLX engine was folded into the main repo, so there is nothing to install
  from here any more.
</p>

---

## Go here instead

```bash
git clone https://github.com/Upinel/UpinelAIOS && cd UpinelAIOS
./install.sh      # scans your Mac, offers a GGUF model and an MLX model
./start.sh        # serves http://<your-lan-ip>:8000/v1
./chat.sh         # talk to it, right here in the terminal
```

**[→ Upinel/UpinelAIOS](https://github.com/Upinel/UpinelAIOS)**

## What changed, and why

This repo was the MLX/MTPLX edition: Qwen through MTPLX, up to 2.6× llama.cpp
on the same model. That work was not thrown away — it is the other half of the
merged project.

The two editions existed because the runtimes were assumed to be exclusive. They
are not, because **the engine is a property of the model, not of the install**:

| model | engine | why |
|---|---|---|
| Gemma 4 (`gguf-g-*`) | llama.cpp | MTPLX cannot serve Gemma 4 — it needs a target/assistant pair, and the only ones that exist are built from aligned models |
| Qwen (`gguf-q-*`) | llama.cpp | works, but MTPLX's MTP runs it faster on Metal |
| Qwen (`mlx-q-*`) | MLX / MTPLX | up to **2.6×** llama.cpp on the same model |

So `./install.sh` in the merged repo offers one model from each engine — the
fastest in that engine your Mac can actually load — and lets you take either or
both. The engine follows whatever alias you pick, and there is no runtime to
choose up front.

## Everything here is preserved

Nothing is deleted. The full history of this edition remains on `main` and in
its tags; it is simply no longer the thing to clone.

- **Aliases** — the MLX aliases were renamed to say which engine they belong to
  (`4bit` → `mlx-q-27b-4bit`, `moe` → `mlx-q-35ba3b`, and so on), but **every
  old name is still accepted** and resolves to exactly the same repo it did
  before. Anything you scripted against `./start.sh --model 4bit` keeps working:
  `4bit`, `6bit`, `27b-3bit`, `27b-4bit`, `9b` and `moe` all still resolve, and
  `27b-4bit` still means the barozp build rather than the itrejomx one.
- **Licence** — the same [Upinel Personal Free License](LICENSE), byte-identical
  (`SHA-256 0906eccc1ebc7e22f8de876997a4f33b7b85c3516d2c5a28796aad759fde7ff7`).
  Free personal use, free for creators, other commercial use by written
  permission, derivatives must credit the author.

---

<p align="center">
  <sub>Built by <b>Nova Upinel Chow</b>, MSc, LLM, BBA, MENSA &nbsp;·&nbsp;
  <a href="mailto:upinel@me.com">upinel@me.com</a> &nbsp;·&nbsp;
  <a href="mailto:dev@upinel.com">dev@upinel.com</a> &nbsp;·&nbsp;
  <a href="https://upinel.com">upinel.com</a></sub>
</p>
