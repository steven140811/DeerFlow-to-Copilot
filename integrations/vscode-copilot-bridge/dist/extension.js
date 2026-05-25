"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.activate = activate;
exports.deactivate = deactivate;
const http = __importStar(require("node:http"));
const https = __importStar(require("node:https"));
const fs = __importStar(require("node:fs"));
const os = __importStar(require("node:os"));
const path = __importStar(require("node:path"));
const vscode = __importStar(require("vscode"));
let server;
let cachedModel;
let outputChannel;
let statusItem;
let launchTerminal;
let lastRequestProbe = {
    status: 'unknown',
    checked_at: null,
    model_id: null,
    error: null,
};
const SUPPORTED_REASONING_EFFORTS = new Set(['none', 'minimal', 'low', 'medium', 'high', 'xhigh']);
const DEFAULT_DEERFLOW_UI_URL = 'http://localhost:2026';
const DEFAULT_LAUNCH_TIMEOUT_MS = 120000;
function getConfig() {
    return vscode.workspace.getConfiguration('deerflowCopilotBridge');
}
function getConfiguredModel() {
    return getConfig().get('model', 'gpt-5.4').trim();
}
function normalizeReasoningEffort(value) {
    if (typeof value !== 'string') {
        return undefined;
    }
    const normalized = value.trim().toLowerCase();
    return SUPPORTED_REASONING_EFFORTS.has(normalized) ? normalized : undefined;
}
function getConfiguredReasoningEffort() {
    return normalizeReasoningEffort(getConfig().get('reasoningEffort', 'xhigh'));
}
function getBridgeAddress() {
    const host = getConfig().get('host', '127.0.0.1');
    const port = getConfig().get('port', 8765);
    return `http://${host}:${port}`;
}
function getRequestTimeoutMs() {
    const configured = getConfig().get('requestTimeoutMs', 90000);
    return Number.isFinite(configured) && configured > 0 ? configured : 90000;
}
function getLaunchTimeoutMs() {
    const configured = getConfig().get('launchTimeoutMs', DEFAULT_LAUNCH_TIMEOUT_MS);
    return Number.isFinite(configured) && configured > 0 ? configured : DEFAULT_LAUNCH_TIMEOUT_MS;
}
function getRepoRoot(context) {
    return path.resolve(context.extensionPath, '..', '..');
}
function normalizeUrl(value) {
    if (typeof value !== 'string') {
        return undefined;
    }
    const trimmed = value.trim();
    return trimmed ? trimmed.replace(/\/+$/, '') : undefined;
}
function getSavedProfilePath() {
    const appData = process.env.APPDATA ?? path.join(os.homedir(), 'AppData', 'Roaming');
    return path.join(appData, 'DeerFlow', 'vscode-to-deerflow.profile.json');
}
function getDeerFlowUiUrl() {
    try {
        const raw = JSON.parse(fs.readFileSync(getSavedProfilePath(), 'utf8'));
        const saved = normalizeUrl(typeof raw.deerflow_url === 'string' ? raw.deerflow_url : undefined);
        if (saved) {
            return saved;
        }
    }
    catch {
    }
    return DEFAULT_DEERFLOW_UI_URL;
}
function getHealthUrl(baseUrl) {
    return `${baseUrl.replace(/\/+$/, '')}/health`;
}
function getTerminalEnv() {
    const env = { ...process.env };
    if (process.platform === 'win32') {
        const appData = process.env.APPDATA ?? path.join(os.homedir(), 'AppData', 'Roaming');
        const separator = ';';
        const currentPath = env.Path ?? env.PATH ?? '';
        const preferredEntries = [
            'C:\\Program Files\\nodejs',
            path.join(appData, 'npm'),
            'C:\\nginx',
            'C:\\Program Files (x86)\\GnuWin32\\bin',
        ];
        const seen = new Set(currentPath.split(separator).filter(Boolean).map(entry => entry.toLowerCase()));
        const additions = preferredEntries.filter(entry => entry && !seen.has(entry.toLowerCase()));
        const nextPath = [...additions, currentPath].filter(Boolean).join(separator);
        env.Path = nextPath;
        env.PATH = nextPath;
    }
    return env;
}
function getLaunchTerminal(context) {
    if (launchTerminal) {
        return launchTerminal;
    }
    launchTerminal = vscode.window.createTerminal({
        name: 'DeerFlow Local Services',
        cwd: getRepoRoot(context),
        env: getTerminalEnv(),
    });
    return launchTerminal;
}
function getTerminalCommand(command) {
    return process.platform === 'win32' ? command : command;
}
async function getUrlStatus(target, timeoutMs = 3000) {
    let parsed;
    try {
        parsed = new URL(target);
    }
    catch {
        return undefined;
    }
    const client = parsed.protocol === 'https:' ? https : parsed.protocol === 'http:' ? http : undefined;
    if (!client) {
        return undefined;
    }
    return await new Promise(resolve => {
        let settled = false;
        const finish = (status) => {
            if (!settled) {
                settled = true;
                resolve(status);
            }
        };
        const request = client.request({
            hostname: parsed.hostname,
            port: parsed.port ? Number(parsed.port) : undefined,
            path: `${parsed.pathname}${parsed.search}`,
            method: 'GET',
            timeout: timeoutMs,
        }, response => {
            response.resume();
            finish(response.statusCode);
        });
        request.on('timeout', () => {
            request.destroy();
            finish();
        });
        request.on('error', () => finish());
        request.end();
    });
}
function sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
}
async function waitForUiReady(baseUrl, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        const status = await getUrlStatus(getHealthUrl(baseUrl), 4000);
        if (status && status >= 200 && status < 300) {
            return true;
        }
        await sleep(2000);
    }
    return false;
}
async function openDeerFlowUi() {
    await vscode.env.openExternal(vscode.Uri.parse(getDeerFlowUiUrl()));
}
async function configureDeerFlowAccount(context) {
    const scriptPath = path.join(getRepoRoot(context), 'scripts', 'configure-vscode-to-deerflow.ps1');
    if (!fs.existsSync(scriptPath)) {
        void vscode.window.showErrorMessage(`Configure script not found: ${scriptPath}`);
        return;
    }
    const terminal = vscode.window.createTerminal({
        name: 'DeerFlow Account Config',
        cwd: getRepoRoot(context),
        env: getTerminalEnv(),
    });
    terminal.show(true);
    terminal.sendText(`pwsh -ExecutionPolicy Bypass -File "${scriptPath}"`, true);
}
async function ensureLocalDeerFlow(context) {
    const baseUrl = getDeerFlowUiUrl();
    const readyBeforeLaunch = await getUrlStatus(getHealthUrl(baseUrl), 2500);
    if (readyBeforeLaunch && readyBeforeLaunch >= 200 && readyBeforeLaunch < 300) {
        return true;
    }
    const terminal = getLaunchTerminal(context);
    terminal.show(true);
    terminal.sendText(getTerminalCommand('make dev-daemon'), true);
    const ready = await waitForUiReady(baseUrl, getLaunchTimeoutMs());
    if (!ready) {
        void vscode.window.showWarningMessage('DeerFlow local services are still starting. The UI will be opened anyway; check the "DeerFlow Local Services" terminal if it is not ready yet.');
    }
    return ready;
}
async function launchWorkbench(context) {
    let bridgeStarted = true;
    try {
        await startBridge(true);
    }
    catch (error) {
        bridgeStarted = false;
        reportBridgeError('launch', error);
    }
    await vscode.window.withProgress({
        location: vscode.ProgressLocation.Notification,
        title: 'Launching DeerFlow workbench',
        cancellable: false,
    }, async (progress) => {
        progress.report({ message: 'Starting local DeerFlow services if needed...' });
        await ensureLocalDeerFlow(context);
        progress.report({ message: 'Opening DeerFlow UI...' });
        await openDeerFlowUi();
    });
    if (bridgeStarted) {
        void vscode.window.showInformationMessage('DeerFlow is ready. Use the browser UI for visual chat, or keep the bridge running for Copilot -> DeerFlow requests.');
    }
}
function setRequestProbe(status, modelId, error) {
    lastRequestProbe = {
        status,
        checked_at: new Date().toISOString(),
        model_id: modelId ?? cachedModel?.id ?? null,
        error: error ?? null,
    };
    updateStatusBar();
}
function requestTimeoutMessage(timeoutMs) {
    return `Copilot request timed out after ${Math.ceil(timeoutMs / 1000)}s. If the Extension Development Host window is prompting for model access, approve it and rerun 'DeerFlow Copilot Bridge: Start'.`;
}
function getOutputChannel() {
    if (!outputChannel) {
        outputChannel = vscode.window.createOutputChannel('DeerFlow Copilot Bridge', { log: true });
    }
    return outputChannel;
}
function updateStatusBar() {
    if (!statusItem) {
        return;
    }
    const configuredModel = getConfiguredModel() || 'copilot-auto';
    const requestState = lastRequestProbe.status === 'ready'
        ? `Request path: ready (${lastRequestProbe.model_id ?? configuredModel})`
        : lastRequestProbe.status === 'error'
            ? `Request path: blocked\n${lastRequestProbe.error ?? 'Unknown error'}`
            : lastRequestProbe.status === 'pending'
                ? 'Request path: checking Copilot access'
                : 'Request path: not checked yet';
    if (server) {
        statusItem.text = '$(plug) DeerFlow Bridge';
        statusItem.tooltip = `Running at ${getBridgeAddress()}\nDefault model: ${configuredModel}\n${requestState}\nClick to stop the bridge.`;
        statusItem.command = 'deerflowCopilotBridge.stop';
    }
    else {
        statusItem.text = '$(debug-disconnect) DeerFlow Bridge';
        statusItem.tooltip = `Stopped\nDefault model: ${configuredModel}\n${requestState}\nClick to start the bridge.`;
        statusItem.command = 'deerflowCopilotBridge.start';
    }
    statusItem.show();
}
function reportBridgeState(message) {
    getOutputChannel().info(message);
    void vscode.window.setStatusBarMessage(message, 5000);
    updateStatusBar();
}
function formatErrorMessage(error) {
    return error instanceof Error ? error.message : String(error);
}
function reportBridgeError(action, error) {
    const message = `DeerFlow Copilot bridge ${action} failed: ${formatErrorMessage(error)}`;
    getOutputChannel().error(message);
    void vscode.window.showErrorMessage(message);
    updateStatusBar();
}
function writeJson(response, statusCode, body) {
    const json = JSON.stringify(body);
    response.writeHead(statusCode, {
        'Content-Type': 'application/json; charset=utf-8',
        'Content-Length': Buffer.byteLength(json),
    });
    response.end(json);
}
function readJsonBody(request, maxBytes = 4 * 1024 * 1024) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        let totalBytes = 0;
        request.on('data', chunk => {
            const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
            totalBytes += buffer.length;
            if (totalBytes > maxBytes) {
                reject(new Error('Request body is too large'));
                request.destroy();
                return;
            }
            chunks.push(buffer);
        });
        request.on('end', () => {
            try {
                const raw = Buffer.concat(chunks).toString('utf8');
                resolve(raw ? JSON.parse(raw) : {});
            }
            catch (error) {
                reject(error);
            }
        });
        request.on('error', reject);
    });
}
function isAuthorized(request) {
    const token = getConfig().get('token', '');
    if (!token) {
        return true;
    }
    return request.headers.authorization === `Bearer ${token}`;
}
function textFromOpenAiContent(content) {
    if (typeof content === 'string') {
        return content;
    }
    if (Array.isArray(content)) {
        return content
            .map(part => {
            if (typeof part === 'string') {
                return part;
            }
            if (part && typeof part === 'object') {
                const typedPart = part;
                if (typedPart.type === 'text' && typeof typedPart.text === 'string') {
                    return typedPart.text;
                }
            }
            return '';
        })
            .join('');
    }
    return '';
}
function toolCallsFromOpenAiMessage(message) {
    const rawToolCalls = Array.isArray(message.tool_calls) ? message.tool_calls : [];
    const toolCalls = [];
    for (const rawToolCall of rawToolCalls) {
        if (!rawToolCall || typeof rawToolCall !== 'object') {
            continue;
        }
        const toolCall = rawToolCall;
        const fn = typeof toolCall.function === 'object' && toolCall.function ? toolCall.function : {};
        const name = typeof fn.name === 'string' ? fn.name : typeof toolCall.name === 'string' ? toolCall.name : '';
        if (!name) {
            continue;
        }
        const rawArguments = typeof fn.arguments === 'string' ? fn.arguments : '{}';
        let input = {};
        try {
            const parsed = JSON.parse(rawArguments);
            if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
                input = parsed;
            }
        }
        catch {
            input = { value: rawArguments };
        }
        const callId = typeof toolCall.id === 'string' ? toolCall.id : `call_${Date.now()}`;
        toolCalls.push(new vscode.LanguageModelToolCallPart(callId, name, input));
    }
    return toolCalls;
}
function openAiMessagesToVsCode(messages) {
    if (!Array.isArray(messages)) {
        return [];
    }
    const result = [];
    const pendingSystemMessages = [];
    for (const rawMessage of messages) {
        if (!rawMessage || typeof rawMessage !== 'object') {
            continue;
        }
        const message = rawMessage;
        const role = typeof message.role === 'string' ? message.role : 'user';
        const text = textFromOpenAiContent(message.content);
        if (role === 'system') {
            if (text) {
                pendingSystemMessages.push(text);
            }
            continue;
        }
        if (role === 'assistant') {
            const parts = [];
            if (text) {
                parts.push(new vscode.LanguageModelTextPart(text));
            }
            parts.push(...toolCallsFromOpenAiMessage(message));
            result.push(vscode.LanguageModelChatMessage.Assistant(parts.length ? parts : ''));
            continue;
        }
        if (role === 'tool') {
            const callId = typeof message.tool_call_id === 'string' ? message.tool_call_id : '';
            result.push(vscode.LanguageModelChatMessage.User([
                new vscode.LanguageModelToolResultPart(callId, [new vscode.LanguageModelTextPart(text)]),
            ]));
            continue;
        }
        const userText = pendingSystemMessages.length
            ? `System instructions:\n${pendingSystemMessages.join('\n\n')}\n\nUser message:\n${text}`
            : text;
        pendingSystemMessages.length = 0;
        result.push(vscode.LanguageModelChatMessage.User(userText));
    }
    if (pendingSystemMessages.length) {
        result.unshift(vscode.LanguageModelChatMessage.User(`System instructions:\n${pendingSystemMessages.join('\n\n')}`));
    }
    return result;
}
function openAiToolsToVsCode(tools) {
    if (!Array.isArray(tools)) {
        return undefined;
    }
    const result = [];
    for (const rawTool of tools) {
        if (!rawTool || typeof rawTool !== 'object') {
            continue;
        }
        const tool = rawTool;
        const fn = typeof tool.function === 'object' && tool.function ? tool.function : tool;
        const name = typeof fn.name === 'string' ? fn.name : '';
        if (!name) {
            continue;
        }
        result.push({
            name,
            description: typeof fn.description === 'string' ? fn.description : '',
            inputSchema: typeof fn.parameters === 'object' && fn.parameters ? fn.parameters : { type: 'object', properties: {} },
        });
    }
    return result.length ? result : undefined;
}
async function listCopilotModels(selector = { vendor: 'copilot' }) {
    return vscode.lm.selectChatModels(selector);
}
async function selectCopilotModel(requestedModel) {
    const requested = typeof requestedModel === 'string' ? requestedModel : '';
    const configuredModel = getConfiguredModel();
    const configuredFamily = getConfig().get('family', '');
    const selectors = [];
    if (requested && requested !== 'copilot-auto') {
        selectors.push({ vendor: 'copilot', id: requested });
        selectors.push({ vendor: 'copilot', family: requested });
    }
    if ((!requested || requested === 'copilot-auto') && configuredModel) {
        selectors.push({ vendor: 'copilot', id: configuredModel });
        selectors.push({ vendor: 'copilot', family: configuredModel });
    }
    if (configuredFamily) {
        selectors.push({ vendor: 'copilot', family: configuredFamily });
    }
    selectors.push({ vendor: 'copilot' });
    for (const selector of selectors) {
        const models = await listCopilotModels(selector);
        if (models.length) {
            cachedModel = models[0];
            return models[0];
        }
    }
    throw new Error('No VS Code Copilot chat models are available. Sign in to GitHub Copilot and grant model access to this extension.');
}
async function handleModels(response) {
    const models = await listCopilotModels();
    writeJson(response, 200, {
        object: 'list',
        data: models.map(model => ({
            id: model.id,
            object: 'model',
            created: 0,
            owned_by: model.vendor,
            vendor: model.vendor,
            family: model.family,
            name: model.name,
            version: model.version,
            max_input_tokens: model.maxInputTokens,
        })),
    });
}
function requestOptionsFromBody(body) {
    const tools = openAiToolsToVsCode(body.tools);
    const reasoningEffort = normalizeReasoningEffort(body.reasoning_effort ?? body.reasoningEffort ?? getConfiguredReasoningEffort());
    const modelOptions = {};
    for (const key of ['temperature', 'max_tokens', 'top_p']) {
        if (body[key] !== undefined) {
            modelOptions[key] = body[key];
        }
    }
    if (reasoningEffort) {
        modelOptions.reasoningEffort = reasoningEffort;
        modelOptions.reasoning_effort = reasoningEffort;
    }
    const options = {
        justification: 'DeerFlow local bridge request',
    };
    if (Object.keys(modelOptions).length) {
        options.modelOptions = modelOptions;
    }
    if (tools) {
        options.tools = tools;
        options.toolMode = body.tool_choice === 'required' ? vscode.LanguageModelChatToolMode.Required : vscode.LanguageModelChatToolMode.Auto;
    }
    return options;
}
async function executeChatRequest(model, messages, requestOptions, timeoutMs = getRequestTimeoutMs()) {
    const cancellation = new vscode.CancellationTokenSource();
    let timeoutHandle;
    const requestPromise = (async () => {
        const chatResponse = await model.sendRequest(messages, requestOptions, cancellation.token);
        let content = '';
        const toolCalls = [];
        for await (const part of chatResponse.stream) {
            if (part instanceof vscode.LanguageModelTextPart) {
                content += part.value;
                continue;
            }
            if (part instanceof vscode.LanguageModelToolCallPart) {
                toolCalls.push({
                    id: part.callId,
                    type: 'function',
                    function: {
                        name: part.name,
                        arguments: JSON.stringify(part.input ?? {}),
                    },
                });
                continue;
            }
            if (typeof part === 'string') {
                content += part;
                continue;
            }
            if (part && typeof part === 'object' && 'value' in part && typeof part.value === 'string') {
                content += part.value;
            }
        }
        return { content, toolCalls };
    })();
    try {
        return await Promise.race([
            requestPromise,
            new Promise((_, reject) => {
                timeoutHandle = setTimeout(() => {
                    cancellation.cancel();
                    reject(new Error(requestTimeoutMessage(timeoutMs)));
                }, timeoutMs);
            }),
        ]);
    }
    finally {
        if (timeoutHandle) {
            clearTimeout(timeoutHandle);
        }
        cancellation.dispose();
    }
}
async function probeCopilotRequest(model) {
    setRequestProbe('pending', model.id);
    const warmupMessages = [vscode.LanguageModelChatMessage.User('Reply with EXACT text: BRIDGE_WARMUP_OK')];
    await executeChatRequest(model, warmupMessages, { justification: 'DeerFlow bridge warmup' }, Math.min(getRequestTimeoutMs(), 30000));
    setRequestProbe('ready', model.id);
}
async function handleChatCompletion(body, response) {
    const model = await selectCopilotModel(body.model);
    const messages = openAiMessagesToVsCode(body.messages);
    if (!messages.length) {
        writeJson(response, 400, { error: { message: 'messages must contain at least one chat message' } });
        return;
    }
    const { content, toolCalls } = await executeChatRequest(model, messages, requestOptionsFromBody(body));
    setRequestProbe('ready', model.id);
    const finishReason = toolCalls.length ? 'tool_calls' : 'stop';
    writeJson(response, 200, {
        id: `chatcmpl-vscode-${Date.now()}`,
        object: 'chat.completion',
        created: Math.floor(Date.now() / 1000),
        model: model.id,
        choices: [
            {
                index: 0,
                message: {
                    role: 'assistant',
                    content,
                    ...(toolCalls.length ? { tool_calls: toolCalls } : {}),
                },
                finish_reason: finishReason,
            },
        ],
    });
}
async function handleRequest(request, response) {
    if (!isAuthorized(request)) {
        writeJson(response, 401, { error: { message: 'Unauthorized' } });
        return;
    }
    const url = new URL(request.url ?? '/', 'http://127.0.0.1');
    try {
        if (request.method === 'GET' && url.pathname === '/health') {
            writeJson(response, 200, {
                ok: true,
                configured_model: getConfiguredModel() || null,
                configured_reasoning_effort: getConfiguredReasoningEffort() ?? null,
                request_ready: lastRequestProbe.status === 'ready',
                request_probe: lastRequestProbe,
                cached_model: cachedModel
                    ? { id: cachedModel.id, vendor: cachedModel.vendor, family: cachedModel.family, name: cachedModel.name, version: cachedModel.version }
                    : null,
            });
            return;
        }
        if (request.method === 'GET' && url.pathname === '/v1/models') {
            await handleModels(response);
            return;
        }
        if (request.method === 'POST' && url.pathname === '/v1/chat/completions') {
            const body = await readJsonBody(request);
            await handleChatCompletion(body, response);
            return;
        }
        writeJson(response, 404, { error: { message: 'Not found' } });
    }
    catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        getOutputChannel().error(`Bridge request failed: ${message}`);
        writeJson(response, 500, { error: { message } });
    }
}
async function startBridge(warmupModel) {
    if (server) {
        reportBridgeState(`DeerFlow Copilot bridge is already running at ${getBridgeAddress()}.`);
        return;
    }
    if (warmupModel) {
        await selectCopilotModel(getConfiguredModel() || 'copilot-auto');
    }
    const host = getConfig().get('host', '127.0.0.1');
    const port = getConfig().get('port', 8765);
    server = http.createServer((request, response) => {
        void handleRequest(request, response);
    });
    await new Promise((resolve, reject) => {
        server?.once('error', reject);
        server?.listen(port, host, () => resolve());
    });
    reportBridgeState(`DeerFlow Copilot bridge listening on ${getBridgeAddress()}${cachedModel ? ` via ${cachedModel.id}` : ''}.`);
    if (warmupModel && cachedModel) {
        try {
            await probeCopilotRequest(cachedModel);
            reportBridgeState(`DeerFlow Copilot bridge verified Copilot requests via ${cachedModel.id}.`);
        }
        catch (error) {
            const message = formatErrorMessage(error);
            setRequestProbe('error', cachedModel.id, message);
            getOutputChannel().warn(`Bridge warmup failed: ${message}`);
            void vscode.window.showWarningMessage(`DeerFlow bridge is listening, but Copilot requests are not ready: ${message}`);
        }
    }
}
async function stopBridge() {
    if (!server) {
        reportBridgeState('DeerFlow Copilot bridge is not running.');
        return;
    }
    const currentServer = server;
    server = undefined;
    cachedModel = undefined;
    lastRequestProbe = { status: 'unknown', checked_at: null, model_id: null, error: null };
    await new Promise((resolve, reject) => {
        currentServer.close(error => (error ? reject(error) : resolve()));
    });
    reportBridgeState('DeerFlow Copilot bridge stopped.');
}
function activate(context) {
    outputChannel = vscode.window.createOutputChannel('DeerFlow Copilot Bridge', { log: true });
    statusItem = vscode.window.createStatusBarItem('deerflowCopilotBridge.status', vscode.StatusBarAlignment.Right, 100);
    context.subscriptions.push(outputChannel, statusItem, vscode.commands.registerCommand('deerflowCopilotBridge.start', async () => {
        try {
            await startBridge(true);
        }
        catch (error) {
            reportBridgeError('start', error);
        }
    }), vscode.commands.registerCommand('deerflowCopilotBridge.launchWorkbench', async () => {
        await launchWorkbench(context);
    }), vscode.commands.registerCommand('deerflowCopilotBridge.openUi', async () => {
        await openDeerFlowUi();
    }), vscode.commands.registerCommand('deerflowCopilotBridge.configureAccount', async () => {
        await configureDeerFlowAccount(context);
    }), vscode.commands.registerCommand('deerflowCopilotBridge.stop', async () => {
        try {
            await stopBridge();
        }
        catch (error) {
            reportBridgeError('stop', error);
        }
    }));
    updateStatusBar();
    getOutputChannel().info(`Activated DeerFlow Copilot bridge (${context.extensionMode === vscode.ExtensionMode.Development ? 'development' : 'production'} mode).`);
    if (getConfig().get('autoStart', false)) {
        void startBridge(true).catch(error => {
            reportBridgeError('auto-start', error);
        });
    }
}
function deactivate() {
    if (!server) {
        updateStatusBar();
        return undefined;
    }
    const currentServer = server;
    server = undefined;
    cachedModel = undefined;
    lastRequestProbe = { status: 'unknown', checked_at: null, model_id: null, error: null };
    updateStatusBar();
    return new Promise((resolve, reject) => {
        currentServer.close(error => (error ? reject(error) : resolve()));
    });
}
//# sourceMappingURL=extension.js.map