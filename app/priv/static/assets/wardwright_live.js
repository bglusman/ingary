(() => {
  const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");

  if (!window.Phoenix || !window.LiveView || !csrfToken) {
    console.error("Wardwright LiveView client could not start.");
    return;
  }

  const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
    params: { _csrf_token: csrfToken }
  });

  liveSocket.connect();
  window.liveSocket = liveSocket;
})();
