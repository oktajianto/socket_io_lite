# Implementation Plan — socket_io_lite

Rencana pengembangan plugin **Socket.IO client** untuk Dart & Flutter, target
publish ke [pub.dev](https://pub.dev). Dikerjakan **bertahap** — satu fase
selesai & teruji dulu sebelum lanjut, bukan semua serentak.

## Visi

Socket.IO client yang **ringan, murni Dart, dan tanpa satu pun dependency**,
tapi **kompatibel penuh dengan server Socket.IO asli** (Node.js, NestJS). Bisa
dipakai di **semua platform Flutter** — Android, iOS, Web, Windows, macOS, Linux
— lewat satu API yang sama.

## Prinsip Desain

1. **Zero dependency** — hanya Dart SDK (`dart:io`/`dart:html` WebSocket bawaan,
   `dart:convert`, `dart:async`). Tidak ada package dari pub. Maintenance ringan,
   skor pub.dev tinggi.
2. **Standard-compatible** — bicara frame Engine.IO v4 / Socket.IO v4 yang sama
   dengan client JS resmi. Server tidak bisa membedakan.
3. **Semua platform** — abstraksi transport + **conditional import** supaya API
   publik identik di native dan Web.
4. **Core yang bisa dites** — parser paket dibuat **murni** (string in → objek
   out), diuji tanpa jaringan.
5. **Wajib minimal, opsional banyak** — `connect` + `on` + `emit` cukup untuk
   kasus dasar; auth, query, reconnect policy, dsb. lewat opsi.

## Kompetitor (yang harus kita kalahkan)

| Package | Kekuatan | Celah yang kita ambil |
|---|---|---|
| `socket_io_client` | Paling populer, fitur lengkap | Sering telat ngejar versi protokol; API relatif berat |
| `web_socket_channel` | Resmi tim Dart, multiplatform | **Bukan** Socket.IO — WebSocket mentah saja |
| `socket_io` (server) | Sisi server Dart | Bukan client |

**Pembeda utama kita:** benar-benar zero-dep, fokus Socket.IO v4 modern, core
parser yang teruji, dan jalan di semua platform lewat satu API.

## Arsitektur Teknis

Socket.IO = dua lapisan di atas WebSocket:

- **Engine.IO** — transport & heartbeat. Frame diawali 1 digit: `0` open, `1`
  close, `2` ping, `3` pong, `4` message.
- **Socket.IO** — di dalam frame `4`. Digit berikut: `0` CONNECT, `1`
  DISCONNECT, `2` EVENT, `3` ACK, `4` CONNECT_ERROR.

Contoh event di kabel: `42["chat:message",{"text":"halo"}]`.

**Strategi multiplatform (kunci "semua platform + zero-dep"):**

- Abstraksi `SocketTransport` (interface) → dua implementasi:
  - **Native** (Android/iOS/desktop): `WebSocket` dari `dart:io`.
  - **Web**: `WebSocket` dari `dart:html` (SDK, tetap zero pub-dependency).
- Disatukan lewat **conditional import**:
  ```dart
  import 'transport/transport_stub.dart'
    if (dart.library.io)   'transport/transport_io.dart'
    if (dart.library.html) 'transport/transport_html.dart';
  ```
- **Transport awal: WebSocket-only** (`?EIO=4&transport=websocket`). Didukung
  penuh server Socket.IO. Fallback HTTP long-polling ditunda (lihat Fase
  lanjutan) karena jarang dibutuhkan app dan menambah kompleksitas besar.

## Struktur File

```
lib/
  socket_io_lite.dart              # barrel export (public API)
  src/
    parser.dart                    # encode/decode paket Engine.IO + Socket.IO (MURNI)
    packet.dart                    # model paket (tipe, namespace, data, ackId)
    engine.dart                    # Engine.IO: handshake, heartbeat, close
    socket.dart                    # Socket.IO: namespace, on/emit/ack (facade SocketIoLite)
    options.dart                   # SocketOptions (auth, query, reconnect, headers)
    transport/
      transport.dart               # interface SocketTransport
      transport_stub.dart          # stub (lempar UnsupportedError)
      transport_io.dart            # dart:io WebSocket (native)
      transport_html.dart          # dart:html WebSocket (web)
example/
  lib/main.dart                    # demo connect/on/emit/ack
  server/                          # server Node/NestJS minimal untuk uji end-to-end
test/
  parser_test.dart                 # uji parser tanpa jaringan
  socket_test.dart                 # uji dispatch event/ack (transport palsu)
```

## Roadmap Bertahap

### Fase 0 — Scaffolding (SELESAI)

- [x] `pubspec.yaml` (nama, deskripsi, topics, constraint SDK/Flutter)
- [x] `README.md` dengan badge sesuai standar plugin, penjelasan protokol
- [x] `LICENSE` (MIT), `CHANGELOG.md`, `analysis_options.yaml`, `.gitignore`

### Fase 1 — Parser murni (SELESAI)

Fondasi paling penting & paling mudah dites. **Tanpa jaringan sama sekali.**

- [x] `packet.dart` — model paket: `enum EnginePacketType`, `enum SocketPacketType`,
      `EnginePacket`, `SocketPacket { type, namespace, data, ackId }`, `Handshake`
- [x] `parser.dart`:
  - [x] `EngineParser.encode/decode` (prefix Engine.IO 1 digit)
  - [x] `SocketParser.encode(SocketPacket) -> String` (EVENT → `2["ev",args]`, dengan ackId)
  - [x] `SocketParser.decode(String) -> SocketPacket` (type + namespace + ackId + JSON)
  - [x] Namespace non-default (`2/admin,["ev",...]`); koma di payload tak salah-baca
  - [x] Handshake `0{...}` → `sid`, `pingInterval`, `pingTimeout`, `upgrades`, `maxPayload`
  - [x] Paket binary ditolak dengan `UnsupportedError` (ditunda ke Fase 9)
- [x] `test/parser_test.dart` — 30 test lulus, `flutter analyze` bersih

### Fase 2 — Transport abstraction + native (SELESAI)

- [x] `transport/transport.dart` — interface `SocketTransport`: `connect(uri, headers)`,
      `send(String)`, `Stream<String> get messages`, `done`, `isConnected`, `close()`
- [x] `transport/transport_stub.dart` — stub (lempar `UnsupportedError`)
- [x] `transport/transport_io.dart` — `IoTransport` pakai `dart:io WebSocket` (native)
- [x] `transport/transport_factory.dart` — conditional import (stub default,
      `dart:io` saat native; Web jatuh ke stub sampai Fase 7)
- [x] `test/transport_io_test.dart` — uji connect/send/echo/close pakai server
      WebSocket loopback (`dart:io`, tanpa dependency); `flutter analyze` bersih

### Fase 3 — Lapisan Engine.IO (SELESAI)

- [x] `engine.dart`:
  - [x] `EngineIo.buildUri` → `.../socket.io/?EIO=4&transport=websocket` (scheme
        http/https dinormalkan ke ws/wss)
  - [x] `open()` → terima `open`, parse & simpan `Handshake` (sid/interval/timeout)
  - [x] **Heartbeat v4**: balas ping `2` → pong `3`; watchdog putus saat lewat
        `pingInterval + pingTimeout`
  - [x] `send()` bungkus payload jadi frame message `4…`; `messages` meng-unwrap;
        tangani frame `close`; `done` saat koneksi tutup
  - [x] Injectable `transportFactory` untuk test
- [x] `test/engine_test.dart` — handshake, echo message, ping→pong, heartbeat
      timeout, close-sebelum-handshake (pakai server Engine.IO loopback)

### Fase 4 — Lapisan Socket.IO + facade (SELESAI — MVP bisa dipakai)

Target: **client bisa nyambung ke NestJS/Node asli, kirim & terima event.** ✅
Terverifikasi end-to-end ke server `socket.io` v4 asli.

- [x] `socket.dart` — `SocketIoLite`:
  - [x] `SocketIoLite.connect(url, {namespace, auth, query, headers, transportFactory})`
  - [x] Kirim CONNECT `40` (atau `40/ns,`), tunggu balasan, simpan `id` (sid)
  - [x] `on(event, handler)` / `off(event)` — dispatch dari frame `42`, filter namespace
  - [x] `emit(event, data)` → `42[...]`; **buffer emit sebelum connect, flush saat connect**
  - [x] `onConnect` / `onDisconnect` / `onError`; `connect_error` → `SocketException`
  - [x] `disconnect()` (kirim `41`) & `dispose()` idempotent
- [x] `socket_io_lite.dart` — barrel export API publik (parser/engine tetap internal)
- [x] `example/server/` — server Node `socket.io` minimal (echo + ack)
- [x] `example/lib/main.dart` — demo connect + on + emit (analyze bersih)
- [x] `test/socket_test.dart` — 7 test dispatch pakai transport palsu
- [x] `test/e2e_real_server_test.dart` — uji ke server asli (tag `e2e`, skip default)
- [x] **Milestone: MVP jalan di native, teruji lawan server resmi**

### Fase 5 — Acknowledgements (SELESAI)

- [x] `emitWithAck(event, [data]) -> Future` — generate ackId, kirim `42<id>[...]`
- [x] Terima ACK `43<id>[...]` → complete Future yang cocok (unwrap arg tunggal)
- [x] `ackTimeout` opsional (di `connect`) → `TimeoutException`
- [x] Pending ack gagal dengan `SocketException` saat koneksi tutup
- [x] Test round-trip ack (transport palsu) + verifikasi ke server asli

### Fase 6 — Reconnection & connection state (SELESAI)

- [x] Exponential backoff (`reconnection`, `reconnectionAttempts`,
      `reconnectionDelay`, `reconnectionDelayMax`) — delay = base·2^(n-1), di-cap
- [x] Event: `onReconnectAttempt`, `onReconnect`, `onReconnectFailed`
- [x] Engine dibuat ulang tiap attempt; namespace CONNECT dikirim ulang;
      listener & config persist di socket (bukan di engine)
- [x] Pending ack digagalkan saat drop; emit di-buffer lagi lalu flush saat pulih
- [x] `dispose()` membatalkan timer reconnect; `disconnect()` = tak reconnect
- [x] Test transport palsu: reconnect+onReconnect, give-up+onReconnectFailed,
      reconnection:false; e2e ke server asli tetap hijau

### Fase 7 — Dukungan Web (dart:html) (SELESAI)

- [x] `transport/transport_html.dart` — `HtmlTransport` pakai `dart:html WebSocket`
      (zero-dep; lint web-only di-suppress dengan justifikasi)
- [x] Conditional import diperluas: `if (dart.library.html) transport_html.dart`
- [x] `flutter build web` example **sukses** (conditional import pilih transport web)
- [x] E2E file dibuat bisa jalan di browser (`--platform chrome`); logika protokol
      bersama sudah teruji penuh di VM
- [x] **Runtime browser TERVERIFIKASI manual** — `flutter run -d chrome` ke server
      asli: connect (dapat sid), emit, dan terima echo semuanya jalan. (Uji
      otomatis `--platform chrome` hang di environment dev karena headless Chrome;
      verifikasi dilakukan di Chrome nyata.)
- [x] Catatan: dart:html = build JS standar; untuk `--wasm` perlu package:web
      (ditunda ke Fase 9, agar tetap zero-dep)
- [x] **Milestone: satu API, jalan di native + web (dua-duanya terverifikasi)**

### Fase 8 — Verifikasi desktop

- [ ] Uji Windows/macOS/Linux (sudah tercakup `dart:io`, tinggal konfirmasi)
- [ ] Catat matriks platform yang sudah diverifikasi di README

### Fase 9 — Opsi lanjutan (opsional, backward-compatible)

Diurutkan dari nilai tertinggi.

**Prioritas tinggi**
- [ ] `options.dart` — `auth` payload (dikirim di CONNECT), `query` params, `extraHeaders`
- [ ] Namespace ganda (`socket.of('/admin')`)
- [ ] `onAny(handler)` untuk menangkap semua event

**Prioritas menengah**
- [ ] Dukungan **binary** (BINARY_EVENT `45` / BINARY_ACK `46` + attachment placeholder)
- [ ] Rooms hanya diatur server; pastikan event broadcast diterima benar

**Prioritas rendah (nice-to-have)**
- [ ] Fallback **HTTP long-polling** + upgrade ke WebSocket (paritas penuh client resmi)
- [ ] Kompatibilitas Engine.IO v3 / Socket.IO v2 (opsional, di belakang flag)
- [ ] Volatile emit

### Fase 10 — Polish & rilis pub.dev

- [ ] Dartdoc pada seluruh API publik
- [ ] README final + contoh lengkap + GIF/diagram + matriks kompatibilitas
- [ ] `.github/workflows/ci.yml` (analyze + test) → badge CI hidup
- [ ] `.pubignore` (kecualikan `example/server`, build)
- [ ] `dart pub publish --dry-run` bersih (0 warning)
- [ ] **Publish v0.1.0**

## Keputusan yang Sudah Diambil

- **Nama package:** `socket_io_lite` (tersedia di pub.dev).
- **Target protokol:** Engine.IO v4 / Socket.IO v4 (server modern). v2/v3 opsional nanti.
- **Transport awal:** WebSocket-only; long-polling ditunda.
- **Multiplatform:** conditional import (`dart:io` native, `dart:html` web).
- **Bahasa dokumentasi:** Inggris (kode & README); plan ini Indonesia.
- **Lisensi:** MIT.
- **Urutan kerja:** parser → transport → engine → socket (MVP) → ack → reconnect
  → web → desktop → opsi lanjutan → rilis. **Satu fase tuntas & teruji sebelum lanjut.**
