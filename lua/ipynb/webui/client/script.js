let notebookData = { cells: [] };
const statusDot = document.getElementById('status-dot');
const statusText = document.getElementById('status-text');
const clearedCells = new Set(); // Track cleared cells for the current execution batch
const executionTimers = {}; // cellId -> { intervalId, startTime }
const executionElapsed = {}; // cellId -> elapsed seconds (persisted across notebook reloads)

// --- Helpers ---
// Notebooks store source/output as arrays of lines; join them for display.
const flat = (v) => (Array.isArray(v) ? v.join('') : v);
const getCellId = (id) => `cell-${id}`;
const getExecStatusId = (id) => `exec-status-${id}`;
// `msg.cell_id` arrives from Neovim; look up the cell by its stable id.
const getCellById = (msg) =>
  (msg.cell_id && notebookData.cells.find((c) => c.id === msg.cell_id)) || null;

// --- Rendering ---

function renderNotebook() {
    const container = document.getElementById('container');
    container.innerHTML = '';
    notebookData.cells.forEach(cell => {
        const cellElem = createCellElement(cell);
        container.appendChild(cellElem);
    });
    Prism.highlightAll();
}

function createCellElement(cell) {
    const div = document.createElement('div');
    const cellType = cell.cell_type;
    div.className = 'cell ' + cellType + '-cell';
    div.id = getCellId(cell.id);

    if (cellType === 'code') {
        const inputArea = document.createElement('div');
        inputArea.className = 'input-area';

        const prompt = document.createElement('div');
        prompt.className = 'prompt';
        prompt.textContent = `[${cell.execution_count || ' '}]`;

        const pre = document.createElement('pre');
        pre.className = 'source language-python';
        const code = document.createElement('code');
        code.textContent = flat(cell.source);
        pre.appendChild(code);

        inputArea.appendChild(prompt);
        inputArea.appendChild(pre);
        div.appendChild(inputArea);

        const outputArea = document.createElement('div');
        outputArea.className = 'output-area';
        if (cell.outputs) {
            cell.outputs.forEach(output => outputArea.appendChild(createOutputElement(output)));
        }
        div.appendChild(outputArea);

        const execIndicator = document.createElement('div');
        execIndicator.id = getExecStatusId(cell.id);
        const elapsed = executionElapsed[cell.id];
        paintExecutionIndicator(execIndicator, elapsed ? 'completed' : 'hidden', elapsed || 0);
        div.appendChild(execIndicator);
    } else {
        // Markdown cell
        const mdArea = document.createElement('div');
        mdArea.className = 'markdown-area';
        mdArea.innerHTML = marked.parse(flat(cell.source));
        div.appendChild(mdArea);
    }
    return div;
}

function createOutputElement(output) {
    const div = document.createElement('div');
    div.className = 'output-item';

    if (output.text) {
        // Stream output (stdout/stderr)
        div.textContent = flat(output.text);
    } else if (output.ename) {
        // Error output (ename/evalue/traceback)
        div.className = 'output-item output-error';
        div.textContent = flat(output.traceback) || (output.ename + ': ' + output.evalue);
    } else if (output.data) {
        // execute_result or display_data
        const data = output.data;

        for (const mime of ['image/png', 'image/jpeg']) {
            if (data[mime]) {
                const img = document.createElement('img');
                img.src = `data:${mime};base64,` + flat(data[mime]).replace(/\s/g, '');
                img.style.maxWidth = '100%';
                img.style.display = 'block';
                img.style.margin = '10px 0';
                div.appendChild(img);
                return div;
            }
        }
        if (data['text/html']) {
            div.innerHTML = flat(data['text/html']);
        } else if (data['text/plain']) {
            div.textContent = flat(data['text/plain']);
        }
    }
    return div;
}

// --- Execution indicators ---

// Paint icon/timer spans into `indicator`.
// state: 'hidden' | 'running' | 'completed'
function paintExecutionIndicator(indicator, state, elapsed) {
    indicator.className = 'execution-indicator' + (state === 'hidden' ? '' : ` ${state}`);
    indicator.innerHTML = '';
    if (state === 'hidden') return;

    const icon = document.createElement('span');
    icon.className = 'icon';
    if (state === 'completed') {
        icon.textContent = '✔';
    }
    const timer = document.createElement('span');
    timer.className = 'timer';
    timer.textContent = `${elapsed.toFixed(1)}s`;
    indicator.appendChild(icon);
    indicator.appendChild(timer);
}

function setExecutionIndicator(cellId, state, elapsed) {
    const indicator = document.getElementById(getExecStatusId(cellId));
    if (indicator) {
        paintExecutionIndicator(indicator, state, elapsed);
    }
}

function startExecutionTimer(cellId) {
    const indicator = document.getElementById(getExecStatusId(cellId));
    if (!indicator) return;

    if (executionTimers[cellId]) {
        clearInterval(executionTimers[cellId].intervalId);
    }

    setExecutionIndicator(cellId, 'running', 0);

    const startTime = Date.now();
    const timer = indicator.querySelector('.timer');
    const intervalId = setInterval(() => {
        const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
        timer.textContent = `${elapsed}s`;
    }, 100);

    executionTimers[cellId] = { intervalId, startTime };
}

function stopExecutionTimer(cellId) {
    const timerData = executionTimers[cellId];
    if (!timerData) return;

    clearInterval(timerData.intervalId);
    delete executionTimers[cellId];

    const elapsed = (Date.now() - timerData.startTime) / 1000;
    executionElapsed[cellId] = elapsed;
    setExecutionIndicator(cellId, 'completed', elapsed);
}

function restoreExecutionState() {
    for (const [cellId, elapsed] of Object.entries(executionElapsed)) {
        setExecutionIndicator(cellId, 'completed', elapsed);
    }
}

// --- UI Updates ---

function updateStatus(connected, pythonPath) {
    if (connected) {
        statusDot.className = 'kernel-ready';
        statusText.textContent = 'Kernel Ready';
        statusText.title = pythonPath || 'Python path unavailable'; // show python path on mouseover
    } else {
        statusDot.className = 'kernel-offline';
        statusText.textContent = 'Kernel Offline';
        statusText.title = '';
    }
}

function highlightCell(cellId) {
    document.querySelectorAll('.cell').forEach(el => el.classList.remove('active'));
    const activeCell = document.getElementById(getCellId(cellId));
    if (activeCell) {
        activeCell.classList.add('active');
        activeCell.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }
}

// --- Communication ---

function handleMessage(msg) {
    const filenameDisplay = document.getElementById('filename');
    switch (msg.type) {
        case 'notebook_loaded':
            notebookData = msg;
            filenameDisplay.textContent = msg.filename || 'Untitled.ipynb';
            clearedCells.clear();
            renderNotebook();
            restoreExecutionState();
            // Update status based on kernel connection state
            if (msg.kernel) {
                updateStatus(msg.kernel.connected, msg.kernel.python_path);
            }
            break;
        case 'kernel_status':
            // Handle kernel status update from Lua side
            updateStatus(msg.connected, msg.python_path);
            break;
        case 'cursor_moved':
            highlightCell(msg.cell_id);
            break;
        case 'stream':
        case 'execute_result':
        case 'display_data':
        case 'error':
            updateCellOutput(msg);
            break;
        case 'execution_complete': {
            const cellInfo = getCellById(msg);
            if (cellInfo) {
                stopExecutionTimer(cellInfo.id);
            }
            break;
        }
        case 'execute_input': {
            // Kernel signals that a cell started execution and provides the execution count.
            // Update the stored notebook data and the prompt UI for the corresponding cell.
            const cellInfo = getCellById(msg);
            if (cellInfo) {
                cellInfo.execution_count = msg.execution_count;
                const cellElem = document.getElementById(getCellId(cellInfo.id));
                if (cellElem) {
                    const prompt = cellElem.querySelector('.prompt');
                    if (prompt) {
                        prompt.textContent = `[${msg.execution_count || ' '}]`;
                    }
                    // Clear previous outputs for this execution so new outputs replace old ones
                    const outputArea = cellElem.querySelector('.output-area');
                    if (outputArea) {
                        outputArea.innerHTML = '';
                    }
                    // Mark this cell as already cleared for the upcoming output messages
                    clearedCells.add(cellElem.id);
                    startExecutionTimer(cellInfo.id);
                }
            }
            break;
        }
    }
}

function updateCellOutput(msg) {
    const cellInfo = getCellById(msg);
    let targetCell = null;
    if (cellInfo) {
        targetCell = document.getElementById(getCellId(cellInfo.id));
    }
    // Fallback to the cell that is currently highlighted (legacy behavior).
    if (!targetCell) {
        targetCell = document.querySelector('.cell.active');
    }
    if (!targetCell) return;
    const outputArea = targetCell.querySelector('.output-area');
    if (!outputArea) return;
    // Clear the output area once per cell for the current execution batch.
    if (!clearedCells.has(targetCell.id)) {
        outputArea.innerHTML = '';
        clearedCells.add(targetCell.id);
    }
    outputArea.appendChild(createOutputElement(msg.content));
}

function connect() {
    let src = new EventSource('/events');
    src.onopen = () => {
        updateStatus(false); // Connected but kernel may not be ready yet
    };
    src.onmessage = (event) => {
        const msg = JSON.parse(event.data);
        handleMessage(msg);
    };
    src.onerror = () => {
        statusDot.className = '';
        statusText.textContent = 'Disconnected';
        statusText.title = '';
    };
}

connect();
