# Loom Air — design (draft, 2026-11-25)

The phone-call operator in front of each user's Loom. The phone does ASR and sends text; Loom Air runs an agent
loop (the operator) that answers in the user's voice persona, hands work to Loom sessions and speaks the results
through infer-gw. Loom stays API-only; infer-gw knows nothing about tenants.

```
phone / web UI ──ws──▶ Air.Call (one per call) ──Bedrock Converse──▶ Sonnet 5.5
                          │   ├─ HTTP + /socket ─▶ the tenant's Loom (Air.Loom, Air.LoomSocket per tenant)
                          │   └─ /gw/warm, /gw/status, /v1/audio/speech (stream, pcm) ─▶ infer-gw
                          └──ws──▶ ringing / answered, text log + PCM frames back to the client
```

## The operator

**Model:** `us.anthropic.claude-sonnet-5-5` on Bedrock (us-west-2, the host's role), Converse, non-streaming, adaptive thinking at
effort `low`: easy turns don't think, and thinking blocks are kept in the history but never spoken. Not `between_tools`
(Sonnet 5.5's thinking-off): with it the model wrote notes to itself before tool calls as text, which got spoken. Sonnet over Haiku since a replay of a
real call against five models (2026-11-25): Haiku is faster per call but less reliable with tools over several turns;
Sonnet got every step right, twice. Non-streaming on purpose: ConverseStream has been flaky on Bedrock and would save
only ~100–300 ms.
Replies are one or two short sentences, so streaming the model buys little; TTS streams instead. Every call's
`usage` goes to `data/usage.jsonl`.

**What it says:** the text of a response *is* what gets spoken. Text and tool calls in one response: the text is
spoken first, then the tools run. Thinking is never spoken, and thinking blocks are not kept in the history (each
is bound to the exact prompt and tools it was made under, and those change once per call, below).

**Ringing, not a cold phase (user, 2026-11-27):** a dialled call rings, and the client plays the ringback
(`data/ringback.wav`: a 2000s 彩铃, two choruses down a G.711 line) while the greeting turn runs and TTS warms up.
It is answered once the greeting is synthesized whole, so the first words come 0.8 s after the ringing stops (a beat,
as when someone picks up), and never before it has rung 5 s, so a warm call still rings. A cold start (~65 s) fits inside the ringback; if TTS
takes longer than the ringback lasts (87.6 s), nobody answers: the client plays the voice saying
「您拨打的电话暂时无人接听，请稍后再拨」 and hangs up. What the user says while it rings is not heard.

So everything the operator writes is spoken, and it has one prompt and one tool list for the whole call. This
replaced a cold phase (2026-11-25..27) in which the operator spoke through pre-recorded clips with a `play_clip`
tool until TTS was ready; that needed a second prompt and tool list, and a history rewrite on warm-up, since the
model kept calling `play_clip` after it was gone.

**Tools:**

| tool | what |
| --- | --- |
| `read_sessions {session_ids}` | status and latest messages: the last few for one session, the last reply (300 chars) each for several, so "keep an eye on these ten" is one call and one round |
| `send_to_session {session_id, text}` | submit a message to an existing session; returns at once, the reply comes later as an event |
| `new_session {title, prompt}` | start a new Loom session with that prompt; the reply comes later as an event |
| `end_call {}` | hang up after saying goodbye |

**Fewest rounds (user, 2026-11-25):** latency-sensitive, so few tools and few tool rounds. The session list is
not a tool: it comes from the lobby channel and goes into the conversation (below). After
`end_call`, `send_to_session` and `new_session` the model is not asked again (it speaks before them); only a
failure goes back to it.

**What it hears** — every user-role message is built by Air from events, never typed by the model:

```
<state loom_tasks_running="<title>; …"/>
<call_started/>                                  the user dialled (it rings until the greeting is ready)
<sessions>- id 「title」 running, 2 min ago …</sessions>   once, at the start (≤ 30, newest first)
<sessions_changed>new …; … now idle; removed …</sessions_changed>   at the top of a turn, only when something changed
<heard>…</heard>                                 the phone's transcript (may have ASR errors)
<loom_reply session="…" title="…">…</loom_reply>   a session finished the turn Air submitted
<loom_error session="…">…</loom_error>
```

Several events that arrive while a turn runs are sent together as the next message. Tool results go in the same
message as toolResult blocks.

**Two outputs:** the Loom session's reply stays the canonical written answer; the operator only speaks a short,
persona-styled version of it and points the user to the session for details.

**Tenant config** (`data/tenants.json`, 0600): Loom URL + token, voice, temperature, persona text, ASR keywords, 
`operator_name`, the name a client shows for the call (in `hello`), and `public_url`, the address its users sign in
to their Loom at.

**Who a client is (user, 2026-11-27):** the web page has the shared app login cookie and names its tenant. An app has
its Loom's login token: `Authorization: Bearer <token>` and `?loom=<the address it signed in to>`. The address picks
the tenant by `public_url`, and that tenant's Loom, at its own `loom_url`, is asked whether the token is one of its
logins (`GET /api/layout`). One sign-in, to the Loom; a login revoked there is shut out here too. A token is only
ever sent to a Loom in tenants.json, never to an address the client gives. Yeses are kept a minute (`Air.Auth`).
The persona and keywords go into the system prompt; voices and clips are private data, never in the repo.

## Call records and memory (user, 2026-11-25)

- **Record:** every call is appended as it happens to `data/calls/<tenant>/<UTC start>.jsonl`: call_start
  (voice, temperature, model), tts changes, each turn's input, heard, say (spoken or not), tools with
  results, Loom replies, errors, call_end. Raw and complete; nothing reads it during a call.
- **Memory:** `data/memory/<tenant>/memory.md`. A call reads it once when it starts and keeps that snapshot to
  the end, at the end of its system prompt (before the cache point, so it stays cached). There is no tool
  for old calls: memory is all the operator knows about them.
- **Rewrite:** when a call ends, `Air.Memory` (one GenServer per tenant, rewrites one at a time, each from
  the latest memory) gives Opus 5.5 the current memory plus the call rendered as a dialogue (with the session
  list it started with) and stores the whole new memory. A call that starts meanwhile simply uses the
  snapshot as it is. The previous version goes to `history/<UTC>.md`. Calls where the user said nothing are
  skipped.
- **What memory holds:** name and how to address them, people they mention, preferences about the operator,
  frequent topics, which sessions do what. Not: dialogue, task results, session status or pending work (live
  state from Loom; a reply that comes back after hang-up is simply in its session). ~1500 characters, English.

## Processes

```
Air.Application
├─ Finch Air.Finch
├─ Registry Air.Registry           LoomSocket per tenant
├─ DynamicSupervisor Air.Sup       Air.Call, Air.LoomSocket, Air.Memory (per tenant)
├─ Task.Supervisor Air.Tasks       model turns, TTS streams, gw polls
└─ Bandit (Air.Web.Router)         page, ringback, clips, /ws (WebSock → Air.Web.Socket)
```

- **Air.Call** (GenServer, one per call, monitors its socket): `tenant`, `messages`, `pending` events, `turn`
  (Task ref or nil), `speech` queue + the Task streaming the current item, `tts` state, `following` (the
  sessions it follows; the running ones, from the lobby list, are the `<state>` tag's Loom tasks). Dial → `/gw/warm`, poll `/gw/status` every 3 s until ready, then every 15 s. A turn is a Task
  (model call + tool loop, ≤ 6 rounds) so the Call keeps handling events; results come back as messages.
- **Air.LoomSocket** (GenServer per tenant): one Mint.WebSocket to the Loom's `/socket` (Phoenix v2 JSON),
  heartbeat every 30 s. **Follows sessions per call (user, 2026-11-25):** `read_sessions`, `send_to_session` and
  `new_session` each `subscribe(session, since_seq, call)`; a call follows a session at most once, so nothing is
  delivered twice. Every `turn_done` of a followed session sends that turn's last `assistant_text` to the call,
  once, whoever started the turn (a message steered into a running turn, then answered by the next one, gives
  two replies, each once). Submits subscribe from the seq before the submit, so the reply cannot slip past.
  Calls are monitored; a call that ends drops its subscriptions.
  `read(session)` joins from `seq - 80` and returns the snapshot. It also joins the lobby (`agents`) and keeps
  the session list current from its pushes. Push, not polling. The list is not put in the system prompt: it
  changes every turn and would break the cache, so the call sends it whole once and then only the diffs.
- **TTS**: one item at a time. `{:tts, text}` streams `/v1/audio/speech` (`voice`, `response_format: pcm`,
  `stream: true`, 24 kHz s16le mono) to the socket as binary frames between `speech` / `speech_end`; the
  client keeps one timeline. Nothing is spoken before the call is answered; the greeting is synthesized whole
  first and sent at once on `answered`.

## Web UI (v1 test client)

A Loom app (`loom-air`, proxy all), behind the shared app login cookie. Dial / hang up, the gateway's state,
a text box standing in for the phone's ASR, and the call log: what was heard, what was said (spoken or not),
tool calls, Loom replies. The text box opens once the call is answered. Audio plays through WebAudio. Later Loom Air moves to its own host and the
iOS app replaces this page.

## Not in v1

Barge-in (interrupting speech), streaming the model, reconnecting a dropped call, a tenant UI, ASR in the cloud.
