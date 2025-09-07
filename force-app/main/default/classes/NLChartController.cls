public with sharing class NLChartController {

    // --------- CONFIG ---------
    private static final String OPENAI_BASE    = 'https://api.openai.com';
    private static final String OPENAI_MODEL_FOR_PLAN = 'gpt-4.1-mini';
    private static final String OPENAI_API_KEY = 'API KEY';
    private static final String OPENAI_ASSISTANT_ID   = 'OPENAI_ASSISTANT_ID';

    // Hard safety rails
    private static final Set<String> ALLOWED_OBJECTS = new Set<String>{'account','contact','opportunity','case'};
    private static final Integer MAX_LIMIT       = 2000;
    private static final Integer MAX_DATASETS    = 5;
    private static final Integer MAX_CSV_BYTES = 3000000;

    // Optional very-light PII token scan (case-insensitive)
    private static final List<String> PII_TOKENS = new List<String>{
        'email','phone','mobile','fax','password','token','ssn','aadhar','pan'
    };

    // ------------- DTOs -------------
    public class DatasetReq { @AuraEnabled public String name; @AuraEnabled public String purpose; @AuraEnabled public String soql; }
    public class ChartSpec { @AuraEnabled public String title; @AuraEnabled public String type; @AuraEnabled public Map<String, Object> spec; @AuraEnabled public String notes; }
    public class Plan { @AuraEnabled public List<DatasetReq> datasets; @AuraEnabled public ChartSpec chart; }

    public class StartResult {
        @AuraEnabled public String jobId;         // encodes threadId|runId
        @AuraEnabled public List<String> csvVersionIds; // Salesforce ContentVersion Ids for downloads
        @AuraEnabled public String status;        // running|done|error
        @AuraEnabled public String message;
        @AuraEnabled public String chartVersionId; // when done
        @AuraEnabled public String chartDownloadUrl; // when done
        @AuraEnabled public String executedPlanJson;
    }

    // ------------- PUBLIC LWC API -------------

    @AuraEnabled(cacheable=false)
    public static StartResult startRun(String promptText) {
        // 1) Ask LLM for plan (multiple SOQLs + chart spec)
        Plan plan = getPlanFromLLM(promptText);

        // 2) Validate the plan & each SOQL (very important)
        validatePlan(plan);

        // 3) Execute SOQLs and build CSVs (NO DML here)
        List<Blob> csvBlobs = new List<Blob>();
        List<String> csvNames = new List<String>();
        for (DatasetReq d : plan.datasets) {
            String soql = ensureWithSecurityEnforced(d.soql);
            List<SObject> rows = Database.query(soql);
            String csv = toCsv(rows);
            Blob b = Blob.valueOf(csv);
            csvBlobs.add(b);
            csvNames.add('dataset_' + d.name + '.csv');
        }

        // Size caps
        if (csvBlobs.size() > MAX_DATASETS) {
            throw new AuraHandledException('Too many datasets; max is ' + MAX_DATASETS);
        }
        for (Blob b : csvBlobs) {
            if (b.size() > MAX_CSV_BYTES) {
                throw new AuraHandledException('CSV too large; per-file max is ' + MAX_CSV_BYTES + ' bytes');
            }
        }

        // 4) Upload CSVs to OpenAI Files (CALLOUTS happen here, before any DML)
        List<String> fileIds = new List<String>();
        for (Integer i = 0; i < csvBlobs.size(); i++) {
            String fileId = openaiUploadFile(csvNames[i], csvBlobs[i], 'text/csv');
            fileIds.add(fileId);
        }

        // Build instruction for CI
        String ciInstruction = buildCIInstruction(plan);

        // Create thread + run (still callouts)
        Map<String,Object> threadResp = openaiCreateThreadWithMessage(ciInstruction, fileIds);
        String threadId = (String)threadResp.get('id');
        Map<String,Object> runResp = openaiCreateRun(threadId, OPENAI_ASSISTANT_ID);
        String runId = (String)runResp.get('id');

        // 5) NOW do DML: store CSVs as ContentVersion for user downloads
        List<String> csvVersionIds = new List<String>();
        for (Integer i = 0; i < csvBlobs.size(); i++) {
            String verId = storeCsvAsContentVersion(csvNames[i], csvBlobs[i]);
            csvVersionIds.add(verId);
        }

        // 6) Return result
        StartResult res = new StartResult();
        res.jobId = threadId + '|' + runId;
        res.csvVersionIds = csvVersionIds;
        res.status = 'running';
        res.executedPlanJson = JSON.serialize(plan);
        return res;
    }

    @AuraEnabled(cacheable=false)
    public static StartResult pollRun(String jobId) {
        // jobId encodes threadId|runId
        List<String> parts = jobId != null ? jobId.split('\\|') : new List<String>();
        if (parts.size() != 2) throw new AuraHandledException('Bad job Id');
        String threadId = parts[0], runId = parts[1];

        Map<String,Object> status = openaiGetRun(threadId, runId);
        String s = (String)status.get('status');

        StartResult res = new StartResult();
        res.jobId = jobId;
        res.status = s;

        if ('completed'.equalsIgnoreCase(s)) {
            // Fetch latest messages; find an image/file from Code Interpreter (assistant messages only)
            Map<String,Object> messages = openaiListMessages(threadId);
            String fileId = findFirstImageOrFileId(messages);
            if (fileId == null) {
                res.status = 'error';
                res.message = 'No chart file was produced.';
                return res;
            }
            // Download the chart and store in Salesforce Files
            Blob chartBlob = openaiDownloadFileContent(fileId);
            String verId = storeBinaryAsContentVersion('chart.png', chartBlob, 'image/png');
            res.chartVersionId = verId;
            res.chartDownloadUrl = '/sfc/servlet.shepherd/version/download/' + verId;
            res.status = 'done';
        } else if ('failed'.equalsIgnoreCase(s) || 'expired'.equalsIgnoreCase(s) || 'cancelled'.equalsIgnoreCase(s)) {
            res.status = 'error';
            res.message = 'OpenAI run ended with status: ' + s;
        }
        return res;
    }

    // ------------- PLAN (LLM) -------------

    private static Plan getPlanFromLLM(String userPrompt) {
        Map<String,Object> body = new Map<String,Object>{
            'model' => OPENAI_MODEL_FOR_PLAN,
            'response_format' => new Map<String,Object>{ 'type' => 'json_object' },
            'messages' => new List<Object>{
                new Map<String,Object>{ 'role' => 'system', 'content' => planSystemPrompt() },
                new Map<String,Object>{ 'role' => 'user',   'content' => userPrompt }
            }
        };

        HttpResponse resp = httpPostJsonChat('/v1/chat/completions', JSON.serialize(body));
        Integer sc = resp.getStatusCode();
        String raw = resp.getBody();
        if (sc >= 300 || String.isBlank(raw)) {
            throw new AuraHandledException('OpenAI chat failed: ' + resp.getStatus() + ' — ' + raw);
        }

        Map<String,Object> parsed = (Map<String,Object>) JSON.deserializeUntyped(raw);
        List<Object> choices = (List<Object>) parsed.get('choices');
        if (choices == null || choices.isEmpty() || choices[0] == null) {
            throw new AuraHandledException('No plan returned from model. Body: ' + raw);
        }

        Map<String,Object> choice0 = (Map<String,Object>) choices[0];
        Map<String,Object> msg = (Map<String,Object>) choice0.get('message');
        if (msg == null) throw new AuraHandledException('No message in choice. Body: ' + raw);

        Object contentAny = msg.get('content');
        if (contentAny == null) throw new AuraHandledException('Empty content from model. Body: ' + raw);

        String content = String.valueOf(contentAny).trim();

        // Defensive: strip code fences if present
        if (content.startsWith('```')) {
            Integer first = content.indexOf('\n');
            Integer last = content.lastIndexOf('```');
            if (first > 0 && last > first) content = content.substring(first + 1, last).trim();
        }

        Map<String,Object> root;
        try {
            root = (Map<String,Object>) JSON.deserializeUntyped(content);
        } catch (Exception ex) {
            throw new AuraHandledException('Failed to parse JSON plan: ' + ex.getMessage() + ' — content: ' + content);
        }

        return mapUntypedToPlan(root);
    }

    private static Plan mapUntypedToPlan(Map<String,Object> root) {
        Plan p = new Plan();
        p.datasets = new List<DatasetReq>();

        // datasets
        List<Object> ds = (List<Object>) root.get('datasets');
        if (ds != null) {
            for (Object o : ds) {
                Map<String,Object> m = (Map<String,Object>) o;
                DatasetReq d = new DatasetReq();
                d.name    = (String) m.get('name');
                d.purpose = (String) m.get('purpose');
                d.soql    = (String) m.get('soql');
                if (!String.isBlank(d.name) && !String.isBlank(d.soql)) {
                    p.datasets.add(d);
                }
            }
        }

        // chart
        Map<String,Object> ch = (Map<String,Object>) root.get('chart');
        if (ch != null) {
            ChartSpec c = new ChartSpec();
            c.title = (String) ch.get('title');
            c.type  = (String) ch.get('type');
            Object specAny = ch.get('spec');
            if (specAny == null) {
                c.spec = new Map<String,Object>();
            } else if (specAny instanceof Map<String,Object>) {
                c.spec = (Map<String,Object>) specAny;
            } else {
                c.spec = new Map<String,Object>{ 'value' => specAny };
            }
            c.notes = (String) ch.get('notes');
            p.chart = c;
        }
        return p;
    }

    private static String planSystemPrompt() {
        return ''
        + 'You are a Salesforce data planner. Convert the user request into a SAFE plan that returns multiple SOQL datasets for charting.' + '\n'
        + 'Respond as strict JSON with this shape:' + '\n'
        + '{' + '\n'
        + '  "datasets": [' + '\n'
        + '    {"name":"str","purpose":"str","soql":"SELECT ... LIMIT 2000"}, ...' + '\n'
        + '  ],' + '\n'
        + '  "chart": {"title":"str","type":"bar|line|pie|combo","spec":{}, "notes":"str"}' + '\n'
        + '}' + '\n'
        + 'Rules: Only read-only SELECT; include LIMIT<=2000; prefer aggregates; '
        + 'allowed objects: Account, Contact, Opportunity, Case; avoid PII; use GROUP BY/buckets where helpful.' + '\n';
    }

    private static void validatePlan(Plan p) {
        if (p == null || p.datasets == null || p.datasets.isEmpty()) {
            throw new AuraHandledException('Invalid plan: no datasets');
        }
        if (p.datasets.size() > MAX_DATASETS) {
            throw new AuraHandledException('Too many datasets requested; max is ' + MAX_DATASETS);
        }
        for (DatasetReq d : p.datasets) {
            if (String.isBlank(d.name) || String.isBlank(d.soql)) throw new AuraHandledException('Invalid dataset');

            String sLower = d.soql.toLowerCase();

            // Reject dangerous parts
            if (sLower.contains(' insert ') || sLower.contains(' update ') || sLower.contains(' delete ') || sLower.contains(' merge ')
             || sLower.contains(' tooling ') || sLower.contains(' apex ') || sLower.contains(' callout ') || sLower.contains('sosl ')) {
                throw new AuraHandledException('Unsafe query rejected');
            }

            if (!sLower.contains(' limit ')) throw new AuraHandledException('Every query must include LIMIT');
            if (!isAllowedMainObject(d.soql)) throw new AuraHandledException('Object not allowed in: ' + d.name);
            if (!enforcesLimitAtMost(d.soql, MAX_LIMIT)) throw new AuraHandledException('LIMIT must be <= ' + MAX_LIMIT);

            checkPIITokens(d.soql);
        }
    }

    // Strictly match the first object after FROM against allowlist
    private static Boolean isAllowedMainObject(String soql) {
        Matcher m = Pattern.compile('(?i)\\bfrom\\s+(\\w+)').matcher(soql);
        if (!m.find()) return false;
        String main = m.group(1).toLowerCase();
        return ALLOWED_OBJECTS.contains(main);
    }

    // Append WITH SECURITY_ENFORCED if not present; insert before ORDER BY / LIMIT / OFFSET if needed
    private static String ensureWithSecurityEnforced(String soql) {
        // If either USER_MODE or SECURITY_ENFORCED is already present, leave it
        if (Pattern.compile('(?i)\\bwith\\s+(user_mode|security_enforced)\\b').matcher(soql).find()) {
            return soql;
        }

        // Insert immediately after the first "FROM <Object>"
        Matcher m = Pattern.compile('(?i)\\bfrom\\s+\\w+').matcher(soql);
        if (m.find()) {
            Integer insertAt = m.end();
            return soql.substring(0, insertAt) + ' WITH SECURITY_ENFORCED' + soql.substring(insertAt);
        }

        // Fallback (rare): append at end
        return soql + ' WITH SECURITY_ENFORCED';
    }

    private static void checkPIITokens(String soql) {
        String s = soql.toLowerCase();
        for (String t : PII_TOKENS) {
            if (s.contains(t)) {
                // choose to warn or block; here we block
                throw new AuraHandledException('Query may include sensitive fields (' + t + '). Refine your prompt.');
            }
        }
    }

    private static Boolean enforcesLimitAtMost(String soql, Integer cap) {
        Matcher m = Pattern.compile('(?i)\\blimit\\s+(\\d+)').matcher(soql);
        if (m.find()) {
            Integer lim = Integer.valueOf(m.group(1));
            return lim <= cap;
        }
        return false;
    }

    // ------------- CSV & FILES -------------

    private static String toCsv(List<SObject> rows) {
        if (rows == null || rows.isEmpty()) return '';

        Set<String> colsSet = new Set<String>();
        for (SObject r : rows) colsSet.addAll(r.getPopulatedFieldsAsMap().keySet());
        List<String> headers = new List<String>();
        headers.addAll(colsSet);
        headers.sort();

        String csv = String.join(headers, ',') + '\n';
        for (SObject r : rows) {
            Map<String,Object> m = r.getPopulatedFieldsAsMap();
            List<String> line = new List<String>();
            for (String h : headers) {
                Object v = m.get(h);
                String cell = v == null ? '' : String.valueOf(v).replace('"','""');
                if (cell.contains(',') || cell.contains('\n') || cell.contains('"')) {
                    cell = '"' + cell + '"';
                }
                line.add(cell);
            }
            csv += String.join(line, ',') + '\n';
        }
        return csv;
    }

    private static String storeCsvAsContentVersion(String filename, Blob data) {
        ContentVersion cv = new ContentVersion(
            Title = filename, PathOnClient = filename, VersionData = data, IsMajorVersion = true
        );
        insert cv;
        return cv.Id;
    }
    private static String storeBinaryAsContentVersion(String filename, Blob data, String mime) {
        ContentVersion cv = new ContentVersion(
            Title = filename, PathOnClient = filename, VersionData = data, IsMajorVersion = true
        );
        insert cv;
        return cv.Id;
    }

    // ------------- HTTP HELPERS -------------

    // Generic POST with Assistants header (for Assistants endpoints only)
    private static HttpResponse httpPostJson(String path, String jsonBody) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(OPENAI_BASE + path);
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + OPENAI_API_KEY);
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('OpenAI-Beta', 'assistants=v2'); // assistants only
        req.setTimeout(120000);
        req.setBody(jsonBody);
        return new Http().send(req);
    }

    // POST for Chat Completions WITHOUT Assistants header
    private static HttpResponse httpPostJsonChat(String path, String jsonBody) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(OPENAI_BASE + path);
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + OPENAI_API_KEY);
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);
        req.setBody(jsonBody);
        return new Http().send(req);
    }

    private static HttpResponse httpGet(String path) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(OPENAI_BASE + path);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + OPENAI_API_KEY);
        req.setHeader('OpenAI-Beta', 'assistants=v2'); // assistants only
        req.setTimeout(120000);
        return new Http().send(req);
    }

    // ------------- OPENAI – FILE UPLOADS & ASSISTANTS -------------

    // Binary multipart upload (no base64 in the part)
    private static String openaiUploadFile(String filename, Blob fileData, String contentType) {
        // RFC-compliant multipart body using base64 for the file part
        String boundary = '--------------------------' + String.valueOf(Crypto.getRandomLong());

        String pre =
            '--' + boundary + '\r\n' +
            'Content-Disposition: form-data; name="purpose"' + '\r\n\r\n' +
            'assistants' + '\r\n' +
            '--' + boundary + '\r\n' +
            'Content-Disposition: form-data; name="file"; filename="' + filename + '"\r\n' +
            'Content-Type: ' + (String.isBlank(contentType) ? 'application/octet-stream' : contentType) + '\r\n' +
            'Content-Transfer-Encoding: base64' + '\r\n\r\n';

        String post = '\r\n--' + boundary + '--';

        // Base64 encode the binary and send as text in the multipart section
        String body = pre + EncodingUtil.base64Encode(fileData) + post;

        HttpRequest req = new HttpRequest();
        req.setEndpoint(OPENAI_BASE + '/v1/files');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + OPENAI_API_KEY);
        req.setHeader('Content-Type', 'multipart/form-data; boundary=' + boundary);
        req.setHeader('OpenAI-Beta', 'assistants=v2'); // for Assistants endpoints
        req.setTimeout(120000);
        req.setBody(body);

        HttpResponse resp = new Http().send(req);
        if (resp.getStatusCode() >= 300) {
            throw new AuraHandledException('OpenAI file upload failed: ' + resp.getStatus() + ' — ' + resp.getBody());
        }
        Map<String,Object> parsed = (Map<String,Object>) JSON.deserializeUntyped(resp.getBody());
        return (String) parsed.get('id');
    }

    private static Map<String,Object> openaiCreateThreadWithMessage(String instruction, List<String> fileIds) {
        List<Object> attachments = new List<Object>();
        for (String fid : fileIds) {
            attachments.add(new Map<String,Object>{
                'file_id' => fid,
                'tools'   => new List<Object>{ new Map<String,Object>{ 'type' => 'code_interpreter' } }
            });
        }
        Map<String,Object> body = new Map<String,Object>{
            'messages' => new List<Object>{
                new Map<String,Object>{
                    'role' => 'user',
                    'content' => new List<Object>{ new Map<String,Object>{ 'type' => 'text', 'text' => instruction } },
                    'attachments' => attachments
                }
            }
        };
        HttpResponse resp = httpPostJson('/v1/threads', JSON.serialize(body));
        if (resp.getStatusCode() >= 300) throw new AuraHandledException('OpenAI create thread failed: ' + resp.getBody());
        return (Map<String,Object>) JSON.deserializeUntyped(resp.getBody());
    }

    private static Map<String,Object> openaiCreateRun(String threadId, String assistantId) {
        Map<String,Object> body = new Map<String,Object>{ 'assistant_id' => assistantId };
        HttpResponse resp = httpPostJson('/v1/threads/' + threadId + '/runs', JSON.serialize(body));
        if (resp.getStatusCode() >= 300) throw new AuraHandledException('OpenAI create run failed: ' + resp.getBody());
        return (Map<String,Object>) JSON.deserializeUntyped(resp.getBody());
    }

    private static Map<String,Object> openaiGetRun(String threadId, String runId) {
        HttpResponse resp = httpGet('/v1/threads/' + threadId + '/runs/' + runId);
        if (resp.getStatusCode() >= 300) throw new AuraHandledException('OpenAI get run failed: ' + resp.getBody());
        return (Map<String,Object>) JSON.deserializeUntyped(resp.getBody());
    }

    private static Map<String,Object> openaiListMessages(String threadId) {
        HttpResponse resp = httpGet('/v1/threads/' + threadId + '/messages?order=desc&limit=20');
        if (resp.getStatusCode() >= 300) throw new AuraHandledException('OpenAI list messages failed: ' + resp.getBody());
        return (Map<String,Object>) JSON.deserializeUntyped(resp.getBody());
    }

    private static String findFirstImageOrFileId(Map<String,Object> messagesResp) {
        List<Object> data = (List<Object>) messagesResp.get('data');
        if (data == null) return null;

        for (Object o : data) {
            Map<String,Object> msg = (Map<String,Object>) o;

            // Prefer assistant messages to avoid grabbing user attachments
            String role = (String) msg.get('role');
            if (role == null || !'assistant'.equalsIgnoreCase(role)) continue;

            List<Object> content = (List<Object>) msg.get('content');
            if (content == null) continue;

            for (Object c : content) {
                Map<String,Object> part = (Map<String,Object>) c;
                String type = (String) part.get('type');

                if ('image_file'.equals(type)) {
                    Map<String,Object> im = (Map<String,Object>) part.get('image_file');
                    String fid = im != null ? (String) im.get('file_id') : null;
                    if (!String.isBlank(fid)) return fid;
                } else if ('file_path'.equals(type)) {
                    Map<String,Object> fp = (Map<String,Object>) part.get('file_path');
                    String fid = fp != null ? (String) fp.get('file_id') : null;
                    if (String.isBlank(fid) && fp != null) fid = (String) fp.get('id');
                    if (!String.isBlank(fid)) return fid;
                } else if ('text'.equals(type)) {
                    Map<String,Object> txt = (Map<String,Object>) part.get('text');
                    List<Object> ann = txt != null ? (List<Object>) txt.get('annotations') : null;
                    if (ann != null) {
                        for (Object a : ann) {
                            Map<String,Object> an = (Map<String,Object>) a;
                            Map<String,Object> fileCite = (Map<String,Object>) an.get('file_citation');
                            if (fileCite != null) {
                                String fid = (String) fileCite.get('file_id');
                                if (!String.isBlank(fid)) return fid;
                            }
                        }
                    }
                }
            }
        }
        return null;
    }

    private static Blob openaiDownloadFileContent(String fileId) {
        HttpResponse resp = httpGet('/v1/files/' + fileId + '/content');
        if (resp.getStatusCode() >= 300) throw new AuraHandledException('OpenAI file download failed: ' + resp.getBody());
        return resp.getBodyAsBlob();
    }

    // ------------- INSTRUCTIONS FOR CODE INTERPRETER -------------

    private static String buildCIInstruction(Plan p) {
        if (p.chart == null) {
            p.chart = new ChartSpec();
            p.chart.spec = new Map<String,Object>();
        } else if (p.chart.spec == null) {
            p.chart.spec = new Map<String,Object>();
        }
        String chartJson = JSON.serialize(p.chart);
        return ''
        + 'You are a data analyst.' + '\n'
        + '- Read the attached CSV or CSVs. Use pandas to clean/join if needed.' + '\n'
        + '- Use this chart spec JSON strictly: ' + chartJson + '\n'
        + '- Generate a single figure; if combo, produce side-by-side subplots.' + '\n'
        + '- Use readable axis labels, rotate long x labels, add thousands separators.' + '\n'
        + '- Save the final chart as "chart.png".' + '\n'
        + '- Also write 3 bullet insights to "summary.txt".' + '\n';
    }
}