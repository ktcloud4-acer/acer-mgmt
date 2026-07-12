const openedGroups = new Set();
const stateLabels = {
  healthy: "healthy",
  running: "running (no healthcheck)",
  starting: "starting",
  unhealthy: "unhealthy",
  completed: "completed",
  stopped: "stopped",
};

function summaryText(group) {
  const parts = [`${group.healthy_count}/${group.total} verified healthy`];
  if (group.running_count) parts.push(`${group.running_count} running`);
  if (group.attention_count) parts.push(`${group.attention_count} attention`);
  return parts.join(" · ");
}

function groupId(name) {
  return name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "") || "other";
}

function addText(parent, tag, value, className) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  element.textContent = value;
  parent.append(element);
  return element;
}

function render(snapshot) {
  const freshness = document.getElementById("freshness");
  freshness.textContent = snapshot.stale ? "STALE DATA — Docker is currently unavailable" : `Updated ${snapshot.captured_at}`;
  freshness.classList.toggle("stale", snapshot.stale);

  const groups = [...snapshot.groups];
  if (snapshot.other.length) {
    groups.push({ name: "Other", total: snapshot.other.length, healthy_count: snapshot.other.filter((item) => item.status === "healthy").length, running_count: snapshot.other.filter((item) => item.status === "running").length, attention_count: snapshot.other.filter((item) => ["starting", "unhealthy", "stopped"].includes(item.status)).length, containers: snapshot.other });
  }

  const summary = document.getElementById("summary");
  const stacks = document.getElementById("stacks");
  summary.replaceChildren();
  stacks.replaceChildren();
  for (const group of groups) {
    const id = groupId(group.name);
    const isOpen = openedGroups.has(id);
    const card = document.createElement("article");
    card.className = "summary-card";
    addText(card, "h2", group.name);
    addText(card, "p", summaryText(group));
    summary.append(card);

    const button = document.createElement("button");
    button.type = "button";
    button.className = "stack-toggle";
    button.setAttribute("aria-expanded", String(isOpen));
    button.setAttribute("aria-controls", `stack-${id}`);
    button.textContent = `${group.name} (${group.total})`;
    const section = document.createElement("section");
    section.id = `stack-${id}`;
    section.hidden = !isOpen;
    for (const container of group.containers) {
      const row = document.createElement("div");
      row.className = "container";
      addText(row, "span", container.name);
      addText(row, "span", container.role);
      addText(row, "span", stateLabels[container.status], `status ${container.status}`);
      section.append(row);
    }
    button.addEventListener("click", () => {
      const expanded = button.getAttribute("aria-expanded") === "true";
      button.setAttribute("aria-expanded", String(!expanded));
      section.hidden = expanded;
      if (expanded) openedGroups.delete(id); else openedGroups.add(id);
    });
    stacks.append(button, section);
  }
}

async function refresh() {
  try {
    const response = await fetch("/api/runtime", { cache: "no-store" });
    if (!response.ok) throw new Error("runtime unavailable");
    render(await response.json());
  } catch (error) {
    const freshness = document.getElementById("freshness");
    freshness.textContent = "Runtime data unavailable";
    freshness.classList.add("stale");
  }
}

refresh();
setInterval(refresh, 15000);
