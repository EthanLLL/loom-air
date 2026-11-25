# Loom Air — design (draft, 2026-11-25)

The phone-call operator in front of each user's Loom. The phone does ASR and sends text; Loom Air runs an agent
loop (the operator) that answers in the user's voice persona, hands work to Loom sessions and speaks the results
through infer-gw. Loom stays API-only; infer-gw knows nothing about tenants.

```
phone / web UI ──ws──▶ Air.Call (one per call) ──Bedrock Converse──▶ Haiku 5.5
                          │   ├─ HTTP + /socket ─▶ the tenant's Loom (Air.Loom, Air.LoomSocket per tenant)
                          │   └─ /gw/warm, /gw/status, /v1/audio/speech (stream, pcm) ─▶ infer-gw
                          └──ws──▶ text log + PCM frames + clip cues back to the client
```

## The operator

**Model:** `us.anthropic.claude-haiku-5-5` on Bedrock (us-west-2, the host's role), Converse, non-streaming.
Replies are one or two short sentences, so streaming the model buys little; TTS streams instead. Every call's
`usage` goes to `data/usage.jsonl`.

**What it says:** the text of a response *is* what gets spoken. Text and tool calls in one response: the text is
spoken first, then the tools run. While TTS is not ready, text is shown in the log but not spoken, so the
operator is told to use clips then.

**Tools:**

| tool | what |
| --- | --- |
| `play_clip {name}` | a pre-recorded clip of the voice (greetings, acks, "wait a moment", goodbye); instant, works while TTS is cold. The names and their words are in the tool description. |
| `read_session {session_id}` | a session's status and its last few user / assistant messages |
| `send_to_session {session_id, text}` | submit a message to an existing session; returns at once, the reply comes later as an event |
| `new_session {title, prompt}` | start a new Loom session with that prompt; the reply comes later as an event |
| `end_call {}` | hang up after saying goodbye |

**Fewest rounds (user, 2026-11-25):** latency-sensitive, so few tools and few tool rounds. The session list is
not a tool: it comes from the lobby channel and goes into the conversation (below). After `play_clip`,
`end_call`, `send_to_session` and `new_session` the model is not asked again (it speaks before them); only a
failure goes back to it.

**What it hears** — every user-role message is built by Air from events, never typed by the model:

```
<state tts="ready | warming 35s | launching | off" tasks="1 running: <title>"/>
<call_started/>                                  the user dialled
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

**Tenant config** (`data/tenants.json`, 0600): Loom URL + token, voice, temperature, persona text, ASR keywords.
The persona and keywords go into the system prompt; voices and clips are private data, never in the repo.

## Call records and memory (user, 2026-11-25)

- **Record:** every call is appended as it happens to `data/calls/<tenant>/<UTC start>.jsonl`: call_start
  (voice, temperature, model), tts changes, each turn's input, heard, say (spoken or not), clips, tools with
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
└─ Bandit (Air.Web.Router)         page, clips, /ws (WebSock → Air.Web.Socket)
```

- **Air.Call** (GenServer, one per call, monitors its socket): `tenant`, `messages`, `pending` events, `turn`
  (Task ref or nil), `speech` queue + the Task streaming the current item, `tts` state, `tasks` (Loom work
  in flight). Dial → `/gw/warm`, poll `/gw/status` every 3 s until ready, then every 15 s. A turn is a Task
  (model call + tool loop, ≤ 6 rounds) so the Call keeps handling events; results come back as messages.
- **Air.LoomSocket** (GenServer per tenant): one Mint.WebSocket to the Loom's `/socket` (Phoenix v2 JSON),
  heartbeat every 30 s. `watch(session, client_msg_id, pid)` joins `agent:<id>` from its current seq; when the
  `user` event with that `client_msg_id` is followed by `turn_done`, the last `assistant_text` goes to `pid`.
  `read(session)` joins from `seq - 80` and returns the snapshot. It also joins the lobby (`agents`) and keeps
  the session list current from its pushes. Push, not polling. The list is not put in the system prompt: it
  changes every turn and would break the cache, so the call sends it whole once and then only the diffs.
- **TTS**: one item at a time. `{:tts, text}` streams `/v1/audio/speech` (`voice`, `response_format: pcm`,
  `stream: true`, 24 kHz s16le mono) to the socket as binary frames between `speech` / `speech_end`;
  `{:clip, name}` sends a cue the client plays from its preloaded clips. The client keeps one timeline.

## Web UI (v1 test client)

A Loom app (`loom-air`, proxy all), behind the shared app login cookie. Dial / hang up, the gateway's state,
a text box standing in for the phone's ASR, and the call log: what was heard, what was said (spoken or not),
clips, tool calls, Loom replies. Audio plays through WebAudio. Later Loom Air moves to its own host and the
iOS app replaces this page.

## Not in v1

Barge-in (interrupting speech), streaming the model, reconnecting a dropped call, a tenant UI, ASR in the cloud.
