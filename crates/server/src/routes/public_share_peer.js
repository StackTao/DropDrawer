// Download data comes directly from the sender's WebRTC data channel.
window.receiveLanShare = async function (base, item, passcode, progress, attempt) {
  if (!window.RTCPeerConnection) throw new Error("WebRTC is unavailable");
  const peer = new RTCPeerConnection({ iceServers: [] });
  let disk;
  let tempName;
  let writer;
  let saved = false;
  let idleTimer;
  let writes = Promise.resolve();
  const chunks = [];
  const windowSize = 512 * 1024;
  const request = async (path, body) => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 10000);
    try {
      const response = await fetch(base + path, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ item_id: item.id, passcode: passcode || null, ...body }),
        signal: controller.signal,
      });
      if (!response.ok) {
        const error = new Error(await response.text());
        error.accessDenied = [401, 403, 404, 410, 429].includes(response.status);
        throw error;
      }
      return await response.json();
    } finally {
      clearTimeout(timer);
    }
  };

  try {
    const channel = peer.createDataChannel("dropdrawer-file", { ordered: true });
    channel.binaryType = "arraybuffer";
    await peer.setLocalDescription(await peer.createOffer());
    const reply = await request("/peer", { sdp: peer.localDescription.sdp });
    await peer.setRemoteDescription({ type: "answer", sdp: reply.sdp });
    if (channel.readyState !== "open") {
      await new Promise((resolve, reject) => {
        const timeout = setTimeout(() => fail(new Error("LAN connection timed out")), 6000);
        function fail(error) {
          clearTimeout(timeout);
          reject(error);
        }
        channel.onopen = () => {
          clearTimeout(timeout);
          resolve();
        };
        channel.onerror = fail;
        channel.onclose = fail;
      });
    }

    // Spool larger transfers to disk when supported by the browser.
    if (item.size >= 32 * 1024 * 1024 && navigator.storage?.getDirectory) {
      try {
        disk = await navigator.storage.getDirectory();
        tempName = "dropdrawer-share-" + reply.session;
        const file = await disk.getFileHandle(tempName, { create: true });
        writer = await file.createWritable();
      } catch {
        if (disk && tempName) await disk.removeEntry(tempName).catch(() => {});
        disk = tempName = writer = undefined;
      }
    }

    attempt.session = reply.session;
    const grant = await request("/peer/" + encodeURIComponent(reply.session) + "/claim");
    let received = 0;
    let lastProgress = -1;
    let failed = false;
    const blob = await new Promise((resolve, reject) => {
      const fail = (error) => {
        failed = true;
        reject(error);
      };
      const resetTimeout = () => {
        clearTimeout(idleTimer);
        idleTimer = setTimeout(() => fail(new Error("File transfer timed out")), 20000);
      };
      channel.onerror = fail;
      channel.onclose = () => fail(new Error("The sender disconnected"));
      channel.onmessage = ({ data }) => {
        resetTimeout();
        writes = writes.then(async () => {
          if (failed) return;
          if (data === "done" && received === item.size) {
            if (writer) await writer.close();
            const file = disk
              ? await (await disk.getFileHandle(tempName)).getFile()
              : new Blob(chunks, { type: "application/octet-stream" });
            if (failed) return;
            clearTimeout(idleTimer);
            channel.send("received");
            resolve(file);
            return;
          }
          if (!(data instanceof ArrayBuffer) || received + data.byteLength > item.size) {
            throw new Error("Unexpected file data");
          }
          if (writer) await writer.write(data);
          else chunks.push(data);
          received += data.byteLength;
          if (received % windowSize === 0) channel.send("ack:" + received);
          const percent = Math.floor((received / item.size) * 100);
          if (percent !== lastProgress) {
            lastProgress = percent;
            progress(percent);
          }
        }).catch(fail);
      };
      resetTimeout();
      progress(0);
      channel.send("start:" + grant.start_token);
    });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = item.name;
    document.body.append(link);
    link.click();
    link.remove();
    saved = true;
    setTimeout(() => {
      URL.revokeObjectURL(url);
      if (disk) disk.removeEntry(tempName).catch(() => {});
    }, 60000);
  } finally {
    clearTimeout(idleTimer);
    if (saved) setTimeout(() => peer.close(), 1000);
    else peer.close();
    if (!saved && writer) {
      await writes;
      await writer.abort().catch(() => {});
    }
    if (!saved && disk && tempName) await disk.removeEntry(tempName).catch(() => {});
  }
};
