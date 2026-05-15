(() => {
  const stateClass = (node) => node.policy_state || "eligible";

  const truncate = (value, limit = 24) => {
    if (!value) return "";
    return value.length > limit ? `${value.slice(0, limit - 1)}...` : value;
  };

  const escapeHtml = (value) =>
    String(value || "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");

  const layoutNodes = (graph, width, height) => {
    const nodes = graph.nodes || [];
    const rootId = graph.root;
    const root = nodes.find((node) => node.id === rootId) || nodes[0];
    const rest = nodes.filter((node) => node.id !== (root && root.id));
    const centerX = width / 2;

    const positioned = [];
    if (root) {
      positioned.push({ ...root, x: centerX, y: 72 });
    }

    const rowY = height - 96;
    const step = width / Math.max(rest.length + 1, 2);
    rest.forEach((node, index) => {
      positioned.push({ ...node, x: step * (index + 1), y: rowY });
    });

    return positioned;
  };

  const nodeById = (nodes) =>
    nodes.reduce((acc, node) => {
      acc[node.id] = node;
      return acc;
    }, {});

  const setInspector = (inspector, graph, node) => {
    if (!inspector || !node) return;

    const receiptFields = escapeHtml((graph.receipt_fields || []).join(", "));
    inspector.innerHTML = `
      <span class="badge ${escapeHtml(stateClass(node))}">${escapeHtml(stateClass(node))}</span>
      <h3>${escapeHtml(node.label || node.id)}</h3>
      <p>${escapeHtml(node.policy_note || "baseline route candidate")}</p>
      <dl class="kv">
        <dt>Type</dt><dd>${escapeHtml(node.type || "route node")}</dd>
        <dt>Node</dt><dd>${escapeHtml(node.id)}</dd>
        <dt>Receipt fields</dt><dd>${receiptFields}</dd>
      </dl>
    `;
  };

  const renderGraph = (element) => {
    const canvas = element.querySelector("[data-graph-canvas]");
    const inspector = element.querySelector("[data-graph-inspector]");
    if (!canvas) return;

    let graph;
    try {
      graph = JSON.parse(element.dataset.routeGraph || "{}");
    } catch (_error) {
      return;
    }

    const width = Math.max(canvas.clientWidth || 720, 520);
    const height = 360;
    const nodes = layoutNodes(graph, width, height);
    const byId = nodeById(nodes);
    const edges = graph.edges || [];

    const edgeMarkup = edges
      .map((edge) => {
        const from = byId[edge.from];
        const to = byId[edge.to];
        if (!from || !to) return "";
        return `<path class="route_graph_edge" d="M ${from.x} ${from.y + 34} C ${from.x} ${(from.y + to.y) / 2}, ${to.x} ${(from.y + to.y) / 2}, ${to.x} ${to.y - 34}" />`;
      })
      .join("");

    const nodeMarkup = nodes
      .map((node) => {
        const klass = stateClass(node);
        const label = escapeHtml(truncate(node.label || node.id));
        const meta = escapeHtml(truncate(node.policy_note || node.type, 34));
        const nodeId = escapeHtml(node.id);
        return `
          <g class="route_graph_node ${escapeHtml(klass)}" data-node-id="${nodeId}" transform="translate(${node.x - 92}, ${node.y - 34})" tabindex="0" role="button" aria-label="${label}">
            <rect width="184" height="68"></rect>
            <text x="12" y="28">${label}</text>
            <text class="node_meta" x="12" y="49">${meta}</text>
          </g>
        `;
      })
      .join("");

    canvas.innerHTML = `
      <svg viewBox="0 0 ${width} ${height}" aria-label="Route graph with policy overlay">
        <defs>
          <marker id="arrow" markerWidth="10" markerHeight="10" refX="7" refY="3" orient="auto" markerUnits="strokeWidth">
            <path d="M0,0 L0,6 L8,3 z" fill="#8b99a5"></path>
          </marker>
        </defs>
        ${edgeMarkup}
        ${nodeMarkup}
      </svg>
    `;

    const selectNode = (node) => {
      canvas.querySelectorAll(".route_graph_node").forEach((item) => {
        item.classList.toggle("selected", item.dataset.nodeId === node.id);
      });
      setInspector(inspector, graph, node);
    };

    canvas.querySelectorAll(".route_graph_node").forEach((item) => {
      const node = byId[item.dataset.nodeId];
      item.addEventListener("click", () => selectNode(node));
      item.addEventListener("keydown", (event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          selectNode(node);
        }
      });
    });

    selectNode(nodes[0]);
  };

  const renderAll = () => {
    document.querySelectorAll("[data-route-graph]").forEach(renderGraph);
  };

  window.addEventListener("DOMContentLoaded", renderAll);
  window.addEventListener("phx:update", renderAll);
})();
