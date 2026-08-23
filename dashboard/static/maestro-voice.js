/* Maestro voice — toggle + push-to-talk. A = this computer (Web Speech). C = droid (mlx_whisper). */
(function () {
  "use strict";

  var SpeechRec = window.SpeechRecognition || window.webkitSpeechRecognition;
  var mounted = null;

  function $(root, sel) {
    return root.querySelector(sel);
  }

  function appendGoal(root, text) {
    var ta = $ (root, "#maestro-goal");
    if (!ta || !text) return;
    var clean = String(text).replace(/\s+/g, " ").trim();
    if (!clean) return;
    ta.value = ta.value ? ta.value.replace(/\s+$/, "") + " " + clean : clean;
    ta.dispatchEvent(new Event("input", { bubbles: true }));
  }

  function setLive(root, msg, kind) {
    var el = $(root, "#maestro-voice-live");
    if (!el) return;
    el.textContent = msg || "";
    el.dataset.kind = kind || "idle";
  }

  function setPressed(btn, on) {
    if (!btn) return;
    btn.setAttribute("aria-pressed", on ? "true" : "false");
    btn.classList.toggle("is-hot", !!on);
  }

  function targetOf(root) {
    var sel = $(root, "#maestro-stt-target");
    return sel ? sel.value : "this";
  }

  function Voice(root) {
    this.root = root;
    this.toggled = false;
    this.holding = false;
    this.rec = null;
    this.media = null;
    this.recorder = null;
    this.chunks = [];
    this.loopTimer = null;
    this.busy = false;
  }

  Voice.prototype.secureOk = function () {
    return window.isSecureContext || location.hostname === "localhost" || location.hostname === "127.0.0.1";
  };

  Voice.prototype.canThis = function () {
    return !!SpeechRec;
  };

  Voice.prototype.warnContext = function () {
    if (this.secureOk()) return false;
    setLive(
      this.root,
      "Mic needs a secure context. In Chrome: chrome://flags → Insecure origins treated as secure → add " +
        location.origin,
      "warn"
    );
    return true;
  };

  Voice.prototype.startThis = function () {
    var self = this;
    if (!SpeechRec) {
      setLive(this.root, "This computer has no Web Speech API. Switch target to droid.", "warn");
      return;
    }
    try {
      this.rec = new SpeechRec();
    } catch (err) {
      setLive(this.root, "Web Speech failed to start: " + err, "warn");
      return;
    }
    this.rec.continuous = true;
    this.rec.interimResults = true;
    this.rec.lang = "en-US";
    this.rec.onresult = function (ev) {
      var interim = "";
      var finalBits = [];
      for (var i = ev.resultIndex; i < ev.results.length; i++) {
        var bit = ev.results[i][0].transcript;
        if (ev.results[i].isFinal) finalBits.push(bit);
        else interim += bit;
      }
      if (finalBits.length) appendGoal(self.root, finalBits.join(" "));
      setLive(self.root, interim ? "…" + interim : "Listening on this computer", "hot");
    };
    this.rec.onerror = function (ev) {
      if (ev.error === "no-speech" || ev.error === "aborted") return;
      setLive(self.root, "This computer: " + ev.error, "warn");
    };
    this.rec.onend = function () {
      if (self.toggled || self.holding) {
        try { self.rec.start(); } catch (e) { /* already started */ }
      }
    };
    try {
      this.rec.start();
      setLive(this.root, "Listening on this computer", "hot");
    } catch (err) {
      setLive(this.root, "Mic blocked: " + err, "warn");
    }
  };

  Voice.prototype.stopThis = function () {
    if (this.rec) {
      try { this.rec.stop(); } catch (e) { /* ignore */ }
      this.rec = null;
    }
  };

  Voice.prototype.startFactory = async function () {
    var self = this;
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      setLive(this.root, "No mediaDevices — cannot send audio to droid.", "warn");
      return;
    }
    try {
      this.media = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch (err) {
      setLive(this.root, "Mic blocked: " + err, "warn");
      return;
    }
    setLive(this.root, "Listening → droid (mlx_whisper)", "hot");
    this.factorySlice();
    if (this.toggled) {
      this.loopTimer = setInterval(function () {
        if (!self.toggled && !self.holding) return;
        self.factorySlice();
      }, 3500);
    }
  };

  Voice.prototype.factorySlice = function () {
    var self = this;
    if (!this.media || this.busy) return;
    this.chunks = [];
    var mime = MediaRecorder.isTypeSupported("audio/webm;codecs=opus")
      ? "audio/webm;codecs=opus"
      : "audio/webm";
    try {
      this.recorder = new MediaRecorder(this.media, { mimeType: mime });
    } catch (err) {
      this.recorder = new MediaRecorder(this.media);
    }
    this.recorder.ondataavailable = function (ev) {
      if (ev.data && ev.data.size) self.chunks.push(ev.data);
    };
    this.recorder.onstop = function () {
      var blob = new Blob(self.chunks, { type: self.recorder.mimeType || "audio/webm" });
      self.chunks = [];
      if (blob.size < 800) return;
      self.sendFactory(blob);
    };
    this.recorder.start();
    setTimeout(function () {
      if (self.recorder && self.recorder.state === "recording") self.recorder.stop();
    }, this.toggled ? 3200 : 120000);
  };

  Voice.prototype.sendFactory = async function (blob) {
    var self = this;
    this.busy = true;
    setLive(this.root, "Sending clip to droid…", "hot");
    var body = new FormData();
    body.append("audio", blob, "clip.webm");
    try {
      var res = await fetch("/maestro/transcribe", { method: "POST", body: body });
      var json = await res.json().catch(function () { return {}; });
      if (!res.ok) {
        setLive(self.root, json.detail || ("droid STT " + res.status), "warn");
        return;
      }
      appendGoal(self.root, json.text || "");
      setLive(self.root, json.text ? "droid: +" + json.text.slice(0, 48) : "droid: (silence)", "ok");
    } catch (err) {
      setLive(self.root, "droid unreachable: " + err, "warn");
    } finally {
      this.busy = false;
    }
  };

  Voice.prototype.stopFactory = function () {
    if (this.loopTimer) {
      clearInterval(this.loopTimer);
      this.loopTimer = null;
    }
    if (this.recorder && this.recorder.state === "recording") {
      try { this.recorder.stop(); } catch (e) { /* ignore */ }
    }
    this.recorder = null;
    if (this.media) {
      this.media.getTracks().forEach(function (t) { t.stop(); });
      this.media = null;
    }
  };

  Voice.prototype.start = function (why) {
    if (this.warnContext()) return;
    if (why === "toggle") this.toggled = true;
    if (why === "ptt") this.holding = true;
    setPressed($(this.root, "#maestro-mic-toggle"), this.toggled);
    setPressed($(this.root, "#maestro-mic-ptt"), this.holding);
    if (targetOf(this.root) === "factory") this.startFactory();
    else this.startThis();
  };

  Voice.prototype.stop = function (why) {
    if (why === "toggle") this.toggled = false;
    if (why === "ptt") this.holding = false;
    if (this.toggled || this.holding) {
      setPressed($(this.root, "#maestro-mic-toggle"), this.toggled);
      setPressed($(this.root, "#maestro-mic-ptt"), this.holding);
      return;
    }
    this.stopThis();
    this.stopFactory();
    setPressed($(this.root, "#maestro-mic-toggle"), false);
    setPressed($(this.root, "#maestro-mic-ptt"), false);
    setLive(this.root, "Mic off", "idle");
  };

  Voice.prototype.bind = function () {
    var self = this;
    var toggle = $(this.root, "#maestro-mic-toggle");
    var ptt = $(this.root, "#maestro-mic-ptt");
    var target = $(this.root, "#maestro-stt-target");
    if (toggle) {
      toggle.addEventListener("click", function (ev) {
        ev.preventDefault();
        if (self.toggled) self.stop("toggle");
        else self.start("toggle");
      });
    }
    if (ptt) {
      function down(ev) {
        ev.preventDefault();
        if (self.holding) return;
        self.start("ptt");
      }
      function up(ev) {
        ev.preventDefault();
        self.stop("ptt");
      }
      ptt.addEventListener("pointerdown", down);
      ptt.addEventListener("pointerup", up);
      ptt.addEventListener("pointerleave", up);
      ptt.addEventListener("pointercancel", up);
    }
    if (target) {
      target.addEventListener("change", function () {
        var was = self.toggled || self.holding;
        if (was) {
          self.stopThis();
          self.stopFactory();
          if (self.toggled || self.holding) self.start(self.toggled ? "toggle" : "ptt");
        }
        setLive(self.root, target.value === "factory" ? "Target: droid" : "Target: this computer", "idle");
      });
    }
    if (!this.canThis()) {
      var opt = this.root.querySelector('#maestro-stt-target option[value="this"]');
      if (opt) opt.textContent = "This computer (no Web Speech)";
    }
    if (this.warnContext()) return;
    setLive(this.root, "Mic off — toggle or hold to talk", "idle");
  };

  function mount(root) {
    if (!root || root.dataset.voiceBound === "1") return;
    if (!$(root, "#maestro-goal") || !$(root, "#maestro-mic-toggle")) return;
    root.dataset.voiceBound = "1";
    var voice = new Voice(root);
    voice.bind();
    mounted = voice;
  }

  function scan() {
    document.querySelectorAll("#maestro-compose").forEach(mount);
  }

  document.addEventListener("DOMContentLoaded", scan);
  document.body && document.body.addEventListener("htmx:afterSwap", scan);
  scan();
})();
