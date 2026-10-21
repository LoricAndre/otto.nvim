// Load with Pi's --extension option, then run /otto-ui-demo in a named Otto session.
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';

export default function (pi: ExtensionAPI) {
  pi.registerCommand('otto-ui-demo', {
    description: 'Exercise Otto native extension UI without a model request',
    handler: async (_args, ctx) => {
      ctx.ui.setTitle('Otto UI demo');
      ctx.ui.setStatus('otto-demo', 'UI demo active');
      ctx.ui.setWidget('otto-demo-above', ['Text widget above the prompt']);
      ctx.ui.setWidget('otto-demo-below', ['Text widget below the prompt'], { placement: 'belowEditor' });
      const choice = await ctx.ui.select('Choose a value', ['First', 'Second']);
      ctx.ui.notify(choice === undefined ? 'Selection cancelled' : `Selected: ${choice}`, 'info');
      if (await ctx.ui.confirm('Edit text?', 'Open a multi-line buffer')) {
        const value = await ctx.ui.editor('Edit demo text', 'First line\nSecond line');
        if (value !== undefined) ctx.ui.setEditorText(value);
      }
      ctx.ui.setStatus('otto-demo', undefined);
      ctx.ui.setWidget('otto-demo-above', undefined);
      ctx.ui.setWidget('otto-demo-below', undefined);
      ctx.ui.notify('UI demo finished', 'info');
    },
  });
}
