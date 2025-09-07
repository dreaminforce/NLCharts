import { LightningElement, track } from 'lwc';
import startRun from '@salesforce/apex/NLChartController.startRun';
import pollRun from '@salesforce/apex/NLChartController.pollRun';

export default class NlChart extends LightningElement {
  @track prompt = '';
  @track running = false;
  @track error;
  jobId;
  chartUrl;
  @track csvLinks = [];
  statusMsg = '';

  // Step timeline state
  @track steps = [];

  // ---- UI helpers ----
  get hasCsvLinks() {
    return this.csvLinks && this.csvLinks.length > 0;
  }

  onPrompt(e) {
    this.prompt = e.target.value;
  }

  // Initialize steps (no Apex changes)
  initSteps() {
    this.steps = [
      this.makeStep('plan', 'Plan with LLM'),
      this.makeStep('validate', 'Validate plan'),
      this.makeStep('soql', 'Run SOQL & build CSVs'),
      this.makeStep('upload', 'Upload datasets to OpenAI'),
      this.makeStep('assistant', 'Assistant run (Code Interpreter)'),
      this.makeStep('save', 'Save chart to Salesforce Files')
    ];
  }

  makeStep(id, label, state = 'pending', note) {
    // map state -> icon & classes
    const map = {
      pending:  { icon: 'utility:dash',      textClass: 'slds-text-color_weak',  badge: null },
      inprogress: { icon: 'utility:clock',     textClass: 'slds-text-color_default', badge: { class: 'slds-badge', text: 'In progress' } },
      completed:{ icon: 'utility:check',     textClass: 'slds-text-color_success', badge: { class: 'slds-badge slds-theme_success', text: 'Done' } },
      error:    { icon: 'utility:error',     textClass: 'slds-text-color_error',  badge: { class: 'slds-badge slds-theme_error', text: 'Error' } }
    };
    const deco = map[state] || map.pending;
    return { id, label, state, icon: deco.icon, textClass: deco.textClass, badge: deco.badge, note };
  }

  setStepState(id, state, note) {
    // Reassign array to trigger re-render
    this.steps = this.steps.map(s => {
      if (s.id === id) {
        return this.makeStep(s.id, s.label, state, note || s.note);
      }
      return s;
    });
  }

  setMany(updates = []) {
    // updates: [{ id, state, note? }, ...]
    const byId = new Map(updates.map(u => [u.id, u]));
    this.steps = this.steps.map(s => {
      if (byId.has(s.id)) {
        const u = byId.get(s.id);
        return this.makeStep(s.id, s.label, u.state, u.note || s.note);
      }
      return s;
    });
  }

  // ---- Flow ----
  async start() {
    this.error = null;
    this.chartUrl = null;
    this.csvLinks = [];
    this.statusMsg = '';

    if (!this.prompt || this.prompt.trim().length < 3) {
      this.error = 'Please enter a meaningful prompt.';
      return;
    }

    this.initSteps();
    this.running = true;

    try {
      // Show early step activity while startRun executes on server
      this.setStepState('plan', 'inprogress', 'Generating safe plan JSON');
      // Callout begins: includes planning, validation, SOQL, upload, run creation (server-side)
      const res = await startRun({ promptText: this.prompt });

      // If we got here, the server finished up to run creation successfully
      this.setMany([
        { id: 'plan', state: 'completed' },
        { id: 'validate', state: 'completed' },
        { id: 'soql', state: 'completed' },
        { id: 'upload', state: 'completed' },
        { id: 'assistant', state: 'inprogress', note: 'Waiting for Code Interpreter to finish' }
      ]);

      this.jobId = res.jobId;

      // Build CSV download links (unchanged)
      (res.csvVersionIds || []).forEach((id, idx) => {
        this.csvLinks = [
          ...this.csvLinks,
          {
            id,
            label: `dataset_${idx + 1}.csv`,
            url: `/sfc/servlet.shepherd/version/download/${id}`
          }
        ];
      });

      // Poll until done or error
      await this.pollUntilDone();
    } catch (e) {
      // If startRun fails, it happened during plan/validate/query/upload/run creation
      this.setStepState('plan', 'error');
      this.error = e?.body?.message || e.message;
      this.running = false;
    }
  }

  async pollUntilDone() {
    // ~3 minutes max (36 * 5s)
    for (let i = 0; i < 36; i++) {
      const res = await pollRun({ jobId: this.jobId });
      this.statusMsg = res.message || res.status;

      // OpenAI statuses: queued | in_progress | completed | failed | ...
      if (res.status === 'done') {
        this.chartUrl = res.chartDownloadUrl;
        this.setMany([
          { id: 'assistant', state: 'completed' },
          { id: 'save', state: 'completed', note: 'Chart saved to Salesforce Files' }
        ]);
        this.running = false;
        return;
      } else if (res.status === 'error') {
        this.setStepState('assistant', 'error', res.message || 'Chart generation failed');
        this.error = res.message || 'Chart generation failed';
        this.running = false;
        return;
      } else {
        // Still running
        this.setStepState('assistant', 'inprogress', (res.message || res.status || '').toString());
      }
      await new Promise(r => setTimeout(r, 5000));
    }
    // Timeout
    this.setStepState('assistant', 'error', 'Timed out waiting for chart');
    this.error = 'Timed out waiting for chart.';
    this.running = false;
  }
}