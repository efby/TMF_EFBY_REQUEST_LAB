(function() {
  const messageHandler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.flowEditor;
  const overlaysCache = new Map();

  const defaultDiagramXML = `<?xml version="1.0" encoding="UTF-8"?>
<bpmn:definitions xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                  xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                  xmlns:bpmndi="http://www.omg.org/spec/BPMN/20100524/DI"
                  xmlns:dc="http://www.omg.org/spec/DD/20100524/DC"
                  xmlns:di="http://www.omg.org/spec/DD/20100524/DI"
                  id="Definitions_1"
                  targetNamespace="http://bpmn.io/schema/bpmn">
  <bpmn:process id="Process_1" isExecutable="false">
    <bpmn:startEvent id="StartEvent_1" name="Start">
      <bpmn:outgoing>Flow_1</bpmn:outgoing>
    </bpmn:startEvent>
    <bpmn:task id="Task_1" name="Request Task">
      <bpmn:incoming>Flow_1</bpmn:incoming>
      <bpmn:outgoing>Flow_2</bpmn:outgoing>
    </bpmn:task>
    <bpmn:endEvent id="EndEvent_1" name="End">
      <bpmn:incoming>Flow_2</bpmn:incoming>
    </bpmn:endEvent>
    <bpmn:sequenceFlow id="Flow_1" sourceRef="StartEvent_1" targetRef="Task_1" />
    <bpmn:sequenceFlow id="Flow_2" sourceRef="Task_1" targetRef="EndEvent_1" />
  </bpmn:process>
  <bpmndi:BPMNDiagram id="BPMNDiagram_1">
    <bpmndi:BPMNPlane id="BPMNPlane_1" bpmnElement="Process_1">
      <bpmndi:BPMNShape id="_BPMNShape_StartEvent_1" bpmnElement="StartEvent_1">
        <dc:Bounds x="160" y="160" width="36" height="36" />
      </bpmndi:BPMNShape>
      <bpmndi:BPMNShape id="Activity_1_di" bpmnElement="Task_1">
        <dc:Bounds x="260" y="138" width="120" height="80" />
      </bpmndi:BPMNShape>
      <bpmndi:BPMNShape id="_BPMNShape_EndEvent_1" bpmnElement="EndEvent_1">
        <dc:Bounds x="460" y="160" width="36" height="36" />
      </bpmndi:BPMNShape>
      <bpmndi:BPMNEdge id="Flow_1_di" bpmnElement="Flow_1">
        <di:waypoint x="196" y="178" />
        <di:waypoint x="260" y="178" />
      </bpmndi:BPMNEdge>
      <bpmndi:BPMNEdge id="Flow_2_di" bpmnElement="Flow_2">
        <di:waypoint x="380" y="178" />
        <di:waypoint x="460" y="178" />
      </bpmndi:BPMNEdge>
    </bpmndi:BPMNPlane>
  </bpmndi:BPMNDiagram>
</bpmn:definitions>`;

  const modeler = new BpmnJS({
    container: "#canvas",
    keyboard: {
      bindTo: document
    }
  });

  (function movePaletteOutsideCanvas() {
    var anchor = document.getElementById("flow-palette-anchor");
    var host = document.getElementById("canvas");
    if (!anchor || !host) {
      return;
    }
    function relocate() {
      var pal = host.querySelector(".djs-palette");
      if (pal && pal.parentNode !== anchor) {
        anchor.appendChild(pal);
        return true;
      }
      return !!pal;
    }
    if (relocate()) {
      return;
    }
    var obs = new MutationObserver(function() {
      if (relocate()) {
        obs.disconnect();
      }
    });
    obs.observe(host, { childList: true, subtree: true });
    window.setTimeout(function() {
      obs.disconnect();
    }, 8000);
  })();

  const eventBus = modeler.get("eventBus");
  const selection = modeler.get("selection");
  const overlays = modeler.get("overlays");
  const elementRegistry = modeler.get("elementRegistry");
  const palette = modeler.get("palette");
  const canvas = modeler.get("canvas");

  /**
   * WebKit/macOS replaces straight quotes with typographic ones while typing in contenteditable
   * (direct editing of sequence flow names / conditions). Normalize so flow conditions stay ASCII.
   */
  (function installDirectEditingAsciiQuotes() {
    const host = document.getElementById("canvas");
    if (!host) {
      return;
    }

    function normalizeTypographicQuotesToAscii(text) {
      if (!text) {
        return text;
      }
      return text
        .replace(/\u201C/g, '"')
        .replace(/\u201D/g, '"')
        .replace(/\u2018/g, "'")
        .replace(/\u2019/g, "'")
        .replace(/\u2032/g, "'")
        .replace(/\u2033/g, '"')
        .replace(/\u00AB/g, '"')
        .replace(/\u00BB/g, '"');
    }

    function getCaretCharacterOffset(root) {
      const sel = window.getSelection();
      if (!sel || !sel.rangeCount) {
        return 0;
      }
      const range = sel.getRangeAt(0);
      if (!root.contains(range.startContainer)) {
        return 0;
      }
      const pre = document.createRange();
      pre.selectNodeContents(root);
      pre.setEnd(range.startContainer, range.startOffset);
      return pre.toString().length;
    }

    function setCaretCharacterOffset(root, offset) {
      const safe = Math.max(0, offset);
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null, false);
      let remaining = safe;
      let node = walker.nextNode();
      while (node) {
        const len = node.length;
        if (remaining <= len) {
          const sel = window.getSelection();
          const range = document.createRange();
          range.setStart(node, remaining);
          range.collapse(true);
          sel.removeAllRanges();
          sel.addRange(range);
          return;
        }
        remaining -= len;
        node = walker.nextNode();
      }
      const sel = window.getSelection();
      const range = document.createRange();
      range.selectNodeContents(root);
      range.collapse(false);
      sel.removeAllRanges();
      sel.addRange(range);
    }

    host.addEventListener(
      "input",
      function(ev) {
        if (ev.isComposing) {
          return;
        }
        const t = ev.target;
        if (!t || !t.classList || !t.classList.contains("djs-direct-editing-content")) {
          return;
        }
        const before = t.textContent;
        const after = normalizeTypographicQuotesToAscii(before);
        if (before === after) {
          return;
        }
        const pos = getCaretCharacterOffset(t);
        t.textContent = after;
        setCaretCharacterOffset(t, Math.min(pos, after.length));
      },
      true
    );
  })();

  function getDiagramViewportPayload() {
    if (!canvas) {
      return null;
    }
    const v = canvas.viewbox();
    if (!v || !Number.isFinite(v.x) || !Number.isFinite(v.y) || !Number.isFinite(v.width) || !Number.isFinite(v.height)) {
      return null;
    }
    if (v.width <= 0 || v.height <= 0 || !Number.isFinite(v.scale) || v.scale <= 0) {
      return null;
    }
    return {
      zoomPercent: Math.round(v.scale * 100),
      viewboxX: v.x,
      viewboxY: v.y,
      viewboxWidth: v.width,
      viewboxHeight: v.height
    };
  }

  function applyStoredViewport(vp) {
    if (!vp || vp === null) {
      return false;
    }
    const w = Number(vp.viewboxWidth);
    const h = Number(vp.viewboxHeight);
    if (!Number.isFinite(w) || !Number.isFinite(h) || w <= 0 || h <= 0) {
      return false;
    }
    const x = Number(vp.viewboxX);
    const y = Number(vp.viewboxY);
    if (!Number.isFinite(x) || !Number.isFinite(y)) {
      return false;
    }
    try {
      canvas.viewbox({
        x: x,
        y: y,
        width: w,
        height: h
      });
      return true;
    } catch (e) {
      return false;
    }
  }

  let viewportChangeTimer = null;
  function scheduleViewportNotify() {
    window.clearTimeout(viewportChangeTimer);
    viewportChangeTimer = window.setTimeout(function() {
      const payload = getDiagramViewportPayload();
      if (payload) {
        post("viewportChanged", payload);
      }
    }, 200);
  }

  eventBus.on("canvas.viewbox.changed", scheduleViewportNotify);

  if (palette) {
    eventBus.on("palette.changed", function() {
      if (!palette.isOpen()) {
        palette.open();
      }
    });
  }

  (function initZoomControls() {
    const canvas = modeler.get("canvas");
    const zoomScroll = modeler.get("zoomScroll", false);
    const root = document.getElementById("flow-zoom-controls");
    const btnIn = document.getElementById("flow-zoom-in");
    const btnOut = document.getElementById("flow-zoom-out");
    const input = document.getElementById("flow-zoom-percent");

    if (!canvas || !root || !btnIn || !btnOut || !input) {
      return;
    }

    const ZOOM_MIN = 0.2;
    const ZOOM_MAX = 4;

    function scaleToPercent(scale) {
      return Math.round(scale * 100);
    }

    function currentScale() {
      return canvas.zoom();
    }

    function syncDisplay() {
      if (document.activeElement === input) {
        return;
      }
      input.value = String(scaleToPercent(currentScale()));
    }

    function applyPercent(raw) {
      const cleaned = String(raw || "").replace(/%/g, "").replace(/,/g, ".").trim();
      if (cleaned === "") {
        syncDisplay();
        return;
      }
      const n = parseFloat(cleaned);
      if (!Number.isFinite(n) || n <= 0) {
        syncDisplay();
        return;
      }
      const pct = Math.max(ZOOM_MIN * 100, Math.min(ZOOM_MAX * 100, n));
      canvas.zoom(pct / 100);
      input.value = String(scaleToPercent(currentScale()));
    }

    function step(delta) {
      if (zoomScroll) {
        zoomScroll.stepZoom(delta);
      } else {
        const s = currentScale();
        const factor = delta > 0 ? 1.12 : 1 / 1.12;
        const next = Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, s * factor));
        canvas.zoom(next);
      }
      syncDisplay();
    }

    root.addEventListener("mousedown", function(e) {
      e.stopPropagation();
    });

    btnIn.addEventListener("click", function() {
      step(1);
    });

    btnOut.addEventListener("click", function() {
      step(-1);
    });

    input.addEventListener("keydown", function(e) {
      e.stopPropagation();
      if (e.key === "Enter") {
        e.preventDefault();
        applyPercent(input.value);
        input.blur();
      }
    });

    input.addEventListener("focus", function() {
      input.select();
    });

    input.addEventListener("blur", function() {
      applyPercent(input.value);
    });

    eventBus.on("canvas.viewbox.changed", syncDisplay);
    syncDisplay();
  })();

  let currentBindings = {};
  let requestLabelsByID = {};
  let currentXML = "";
  let changeTimer = null;

  const semanticClassNames = [
    "flow-node-start",
    "flow-node-end",
    "flow-node-task",
    "flow-node-timer",
    "flow-node-exclusive",
    "flow-node-parallel",
    "flow-sequence-flow",
    "flow-bound-task",
    "flow-unbound-task",
    "flow-parallel-fork",
    "flow-parallel-join"
  ];

  function post(type, payload) {
    if (!messageHandler) {
      return;
    }
    messageHandler.postMessage(Object.assign({ type: type }, payload || {}));
  }

  function normalizeNodeType(type) {
    switch (type) {
    case "bpmn:StartEvent":
      return "startEvent";
    case "bpmn:EndEvent":
      return "endEvent";
    case "bpmn:ExclusiveGateway":
      return "exclusiveGateway";
    case "bpmn:ParallelGateway":
      return "parallelGateway";
    default:
      if (/Task$/.test(type) || type === "bpmn:CallActivity") {
        return "task";
      }
      return "unsupported";
    }
  }

  function getEventDefinitions(businessObject) {
    if (!businessObject || !Array.isArray(businessObject.eventDefinitions)) {
      return [];
    }
    return businessObject.eventDefinitions;
  }

  function readExpressionValue(expression) {
    if (!expression) {
      return "";
    }
    if (typeof expression.body === "string" && expression.body.trim()) {
      return expression.body.trim();
    }
    if (typeof expression.text === "string" && expression.text.trim()) {
      return expression.text.trim();
    }
    if (typeof expression.value === "string" && expression.value.trim()) {
      return expression.value.trim();
    }
    return "";
  }

  function extractTimerDefinition(businessObject) {
    const timerDefinition = getEventDefinitions(businessObject).find(function(definition) {
      return definition && definition.$type === "bpmn:TimerEventDefinition";
    });

    if (!timerDefinition) {
      return "";
    }

    return (
      readExpressionValue(timerDefinition.timeDuration) ||
      readExpressionValue(timerDefinition.timeDate) ||
      readExpressionValue(timerDefinition.timeCycle)
    );
  }

  function resolveNodeType(element) {
    if (!element) {
      return "unsupported";
    }

    const businessObject = element.businessObject || {};
    if ((element.type || "") === "bpmn:IntermediateCatchEvent") {
      return extractTimerDefinition(businessObject) || getEventDefinitions(businessObject).some(function(definition) {
        return definition && definition.$type === "bpmn:TimerEventDefinition";
      }) ? "timerEvent" : "unsupported";
    }

    return normalizeNodeType(element.type || "");
  }

  function isConnectableElement(element) {
    return element && element.businessObject && element.type && !element.labelTarget && element.type !== "bpmn:Process";
  }

  function getSummary() {
    const allElements = elementRegistry.getAll().filter(isConnectableElement);
    const nodes = [];
    const connections = [];

    allElements.forEach(function(element) {
      if (element.waypoints) {
        const businessObject = element.businessObject || {};
        connections.push({
          id: businessObject.id || element.id,
          sourceID: businessObject.sourceRef ? businessObject.sourceRef.id : "",
          targetID: businessObject.targetRef ? businessObject.targetRef.id : "",
          name: businessObject.name || "",
          isDefault: !!(businessObject.sourceRef && businessObject.sourceRef.default && businessObject.sourceRef.default.id === businessObject.id)
        });
        return;
      }

      const businessObject = element.businessObject || {};
      const nodeType = resolveNodeType(element);
      nodes.push({
        id: businessObject.id || element.id,
        name: businessObject.name || "",
        bpmnType: element.type || "",
        nodeType: nodeType,
        timerDefinition: nodeType === "timerEvent" ? extractTimerDefinition(businessObject) : "",
        incomingIDs: (businessObject.incoming || []).map(function(item) { return item.sourceRef ? item.sourceRef.id : item.id; }).filter(Boolean),
        outgoingIDs: (businessObject.outgoing || []).map(function(item) { return item.targetRef ? item.targetRef.id : item.id; }).filter(Boolean)
      });
    });

    connections.sort(function(a, b) {
      if (a.sourceID !== b.sourceID) {
        return a.sourceID < b.sourceID ? -1 : a.sourceID > b.sourceID ? 1 : 0;
      }
      const shape = elementRegistry.get(a.sourceID);
      const outgoing = shape && shape.businessObject && shape.businessObject.outgoing;
      if (!outgoing || !outgoing.length) {
        return 0;
      }
      function flowIndex(flowId) {
        for (var i = 0; i < outgoing.length; i++) {
          if (outgoing[i].id === flowId) {
            return i;
          }
        }
        return 100000;
      }
      return flowIndex(a.id) - flowIndex(b.id);
    });

    return {
      nodes: nodes,
      connections: connections
    };
  }

  function semanticClassesForNode(node) {
    const classes = [];

    switch (node.nodeType) {
    case "startEvent":
      classes.push("flow-node-start");
      break;
    case "endEvent":
      classes.push("flow-node-end");
      break;
    case "task":
      classes.push("flow-node-task");
      classes.push(currentBindings[node.id] ? "flow-bound-task" : "flow-unbound-task");
      break;
    case "timerEvent":
      classes.push("flow-node-timer");
      break;
    case "exclusiveGateway":
      classes.push("flow-node-exclusive");
      break;
    case "parallelGateway":
      classes.push("flow-node-parallel");
      if (node.outgoingIDs.length > 1) {
        classes.push("flow-parallel-fork");
      }
      if (node.incomingIDs.length > 1) {
        classes.push("flow-parallel-join");
      }
      break;
    default:
      break;
    }

    return classes;
  }

  function applySemanticClasses(summary) {
    const currentSummary = summary || getSummary();

    currentSummary.nodes.forEach(function(node) {
      const gfx = elementRegistry.getGraphics(node.id);
      if (!gfx) {
        return;
      }
      semanticClassNames.forEach(function(className) {
        gfx.classList.remove(className);
      });
      semanticClassesForNode(node).forEach(function(className) {
        gfx.classList.add(className);
      });
    });

    currentSummary.connections.forEach(function(connection) {
      const gfx = elementRegistry.getGraphics(connection.id);
      if (!gfx) {
        return;
      }
      semanticClassNames.forEach(function(className) {
        gfx.classList.remove(className);
      });
      gfx.classList.add("flow-sequence-flow");
    });
  }

  function getSelectedElementPayload() {
    const selected = selection.get() || [];
    const element = selected[0];
    if (!element || !isConnectableElement(element)) {
      return {
        elementID: null,
        name: "",
        bpmnType: "",
        nodeType: "unsupported"
      };
    }

    return {
      elementID: element.businessObject && element.businessObject.id ? element.businessObject.id : element.id,
      name: (element.businessObject && element.businessObject.name) || "",
      bpmnType: element.type || "",
      nodeType: element.waypoints ? "unsupported" : resolveNodeType(element)
    };
  }

  function elementInteractionPayload(el) {
    if (!el || !isConnectableElement(el)) {
      return null;
    }
    return {
      elementID: el.businessObject && el.businessObject.id ? el.businessObject.id : el.id,
      name: (el.businessObject && el.businessObject.name) || "",
      bpmnType: el.type || "",
      nodeType: el.waypoints ? "unsupported" : resolveNodeType(el)
    };
  }

  function clearBadges() {
    overlaysCache.forEach(function(overlayID) {
      overlays.remove(overlayID);
    });
    overlaysCache.clear();
  }

  function renderBadges() {
    clearBadges();

    const summary = getSummary();
    applySemanticClasses(summary);
    summary.nodes.forEach(function(node) {
      if (node.nodeType === "task") {
        const binding = currentBindings[node.id];
        const requestName = binding && requestLabelsByID[binding] ? requestLabelsByID[binding] : null;
        const element = elementRegistry.get(node.id);
        const badge = document.createElement("div");
        badge.className = "flow-badge flow-badge-above" + (requestName ? "" : " unbound");
        badge.textContent = requestName || "Unbound";

        const overlayID = overlays.add(node.id, {
          position: {
            top: -18,
            left: Math.round((element && element.width ? element.width : 0) / 2)
          },
          html: badge
        });

        overlaysCache.set(node.id, overlayID);
        return;
      }

      if (node.nodeType === "parallelGateway") {
        let label = "";
        let extraClass = "parallel";

        if (node.outgoingIDs.length > 1 && node.incomingIDs.length <= 1) {
          label = "Fork " + node.outgoingIDs.length;
        } else if (node.incomingIDs.length > 1 && node.outgoingIDs.length <= 1) {
          label = "Join " + node.incomingIDs.length;
          extraClass = "join";
        } else if (node.incomingIDs.length > 1 && node.outgoingIDs.length > 1) {
          label = "Sync";
        }

        if (!label) {
          return;
        }

        const badge = document.createElement("div");
        badge.className = "flow-badge " + extraClass;
        badge.textContent = label;

        const overlayID = overlays.add(node.id, {
          position: {
            top: -12,
            right: -10
          },
          html: badge
        });

        overlaysCache.set(node.id, overlayID);
        return;
      }

      if (node.nodeType === "timerEvent") {
        const label = node.timerDefinition || node.name || "Delay";
        const badge = document.createElement("div");
        badge.className = "flow-badge timer";
        badge.textContent = label;

        const overlayID = overlays.add(node.id, {
          position: {
            top: -12,
            right: -10
          },
          html: badge
        });

        overlaysCache.set(node.id, overlayID);
      }
    });
  }

  async function emitDiagramChanged() {
    const saved = await modeler.saveXML({ format: true });
    currentXML = saved.xml;
    renderBadges();
    const diagramViewport = getDiagramViewportPayload();
    const payload = {
      xml: currentXML,
      summary: getSummary()
    };
    if (diagramViewport) {
      payload.diagramViewport = diagramViewport;
    }
    post("diagramChanged", payload);
  }

  function scheduleDiagramChanged() {
    window.clearTimeout(changeTimer);
    changeTimer = window.setTimeout(function() {
      emitDiagramChanged().catch(function(error) {
        post("error", { message: String(error) });
      });
    }, 150);
  }

  // Higher priority than label editing (default 1000): open Swift task sheet on double-click instead of inline rename.
  eventBus.on("element.dblclick", 2500, function(event) {
    const el = event.element;
    if (!el || el === canvas.getRootElement()) {
      return;
    }
    const payload = elementInteractionPayload(el);
    if (!payload || payload.nodeType !== "task") {
      return;
    }
    post("taskDoubleClicked", payload);
    return false;
  });

  eventBus.on("selection.changed", function() {
    post("selectionChanged", getSelectedElementPayload());
  });

  eventBus.on("commandStack.changed", scheduleDiagramChanged);
  eventBus.on("import.done", function() {
    scheduleDiagramChanged();
    post("selectionChanged", getSelectedElementPayload());
  });

  /** Ids that currently have the diagram-js execution marker (see canvas.addMarker). */
  let lastExecutionHighlightIds = [];

  function isFlowHighlightedTaskLike(element) {
    if (!element || !element.type) {
      return false;
    }
    switch (element.type) {
      case "bpmn:Task":
      case "bpmn:UserTask":
      case "bpmn:ServiceTask":
      case "bpmn:ScriptTask":
      case "bpmn:BusinessRuleTask":
      case "bpmn:SendTask":
      case "bpmn:ReceiveTask":
      case "bpmn:ManualTask":
      case "bpmn:CallActivity":
        return true;
      default:
        return false;
    }
  }

  function isFlowHighlightedExclusiveIfGateway(element) {
    return element && element.type === "bpmn:ExclusiveGateway";
  }

  function isFlowHighlightedIntermediateEvent(element) {
    if (!element || !element.type) {
      return false;
    }
    switch (element.type) {
      case "bpmn:IntermediateCatchEvent":
      case "bpmn:IntermediateThrowEvent":
        return true;
      default:
        return false;
    }
  }

  function clearExecutionHighlightMarkers() {
    lastExecutionHighlightIds.forEach(function(id) {
      try {
        if (elementRegistry.get(id)) {
          canvas.removeMarker(id, "flow-execution-active");
          canvas.removeMarker(id, "flow-execution-active-task");
          canvas.removeMarker(id, "flow-execution-active-if");
          canvas.removeMarker(id, "flow-execution-active-intermediate");
        }
      } catch (_e) {
      }
    });
    lastExecutionHighlightIds = [];
  }

  function applyExecutionHighlightsToCanvas(ids) {
    clearExecutionHighlightMarkers();
    if (!ids || !ids.length) {
      return;
    }
    ids.forEach(function(id) {
      const element = elementRegistry.get(id);
      if (!element) {
        return;
      }
      canvas.addMarker(id, "flow-execution-active");
      if (isFlowHighlightedTaskLike(element)) {
        canvas.addMarker(id, "flow-execution-active-task");
      } else if (isFlowHighlightedExclusiveIfGateway(element)) {
        canvas.addMarker(id, "flow-execution-active-if");
      } else if (isFlowHighlightedIntermediateEvent(element)) {
        canvas.addMarker(id, "flow-execution-active-intermediate");
      }
      lastExecutionHighlightIds.push(id);
    });
  }

  window.FlowEditorBridge = {
    createNewDiagram: async function() {
      await modeler.importXML(defaultDiagramXML);
    },
    importXML: async function(xml, viewport) {
      clearExecutionHighlightMarkers();
      const incoming = String(xml || "").trim();
      await modeler.importXML(incoming || defaultDiagramXML);
      if (viewport && typeof viewport === "object" && Number(viewport.viewboxWidth) > 0) {
        window.requestAnimationFrame(function() {
          applyStoredViewport(viewport);
        });
      }
    },
    setExecutionHighlights: function(ids) {
      applyExecutionHighlightsToCanvas(Array.isArray(ids) ? ids : []);
    },
    setBindings: function(bindings, requestLabels) {
      currentBindings = bindings || {};
      requestLabelsByID = requestLabels || {};
      renderBadges();
    },
    exportState: async function() {
      const saved = await modeler.saveXML({ format: true });
      currentXML = saved.xml;
      const diagramViewport = getDiagramViewportPayload();
      const out = {
        xml: currentXML,
        summary: getSummary(),
        selectedElement: getSelectedElementPayload()
      };
      if (diagramViewport) {
        out.diagramViewport = diagramViewport;
      }
      return out;
    },
    focusElement: function(elementID) {
      const elementRegistry = modeler.get("elementRegistry");
      const canvas = modeler.get("canvas");
      const target = elementRegistry.get(elementID);
      if (!target) {
        return false;
      }
      selection.select(target);
      canvas.scrollToElement(target, { center: true });
      return true;
    },
    setTaskName: function(elementID, name) {
      const modeling = modeler.get("modeling");
      const elementRegistry = modeler.get("elementRegistry");
      const el = elementRegistry.get(elementID);
      if (!el) {
        return false;
      }
      const text = name == null ? "" : String(name);
      modeling.updateLabel(el, text);
      scheduleDiagramChanged();
      return true;
    },
    removeElement: function(elementID) {
      const modeling = modeler.get("modeling");
      const elementRegistry = modeler.get("elementRegistry");
      const el = elementRegistry.get(elementID);
      if (!el) {
        return false;
      }
      modeling.removeElements([ el ]);
      selection.select([]);
      scheduleDiagramChanged();
      return true;
    }
  };

  window.addEventListener("load", function() {
    window.FlowEditorBridge.createNewDiagram().then(function() {
      post("ready");
    }).catch(function(error) {
      post("error", { message: String(error) });
    });
  });
})();
