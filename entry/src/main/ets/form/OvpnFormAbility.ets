import { Want } from '@kit.AbilityKit';
import { FormExtensionAbility, formBindingData, formInfo, formProvider } from '@kit.FormKit';
import { ControlClient } from '../service/ControlClient';
import { FormSync } from '../service/FormSync';

export default class OvpnFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const id = String(want.parameters?.['ohos.extra.param.key.form_identity'] ?? '');
    const sync = new FormSync(this.context);
    if (id.length > 0) sync.add(id);
    const snapshot = new ControlClient(this.context).cached();
    const data = sync.data(snapshot, id);
    data.dimension = Number(want.parameters?.[formInfo.FormParam.DIMENSION_KEY] ?? formInfo.FormDimension.Dimension_2_2);
    return formBindingData.createFormBindingData(data);
  }

  onSizeChanged(formId: string, newDimension: formInfo.FormDimension, _newRect: formInfo.Rect): void {
    formProvider.updateForm(formId, formBindingData.createFormBindingData({ dimension: newDimension })).catch(() => {});
  }

  async onUpdateForm(formId: string): Promise<void> {
    const snapshot = await new ControlClient(this.context).query();
    await new FormSync(this.context).update(snapshot, formId);
  }

  onRemoveForm(formId: string): void {
    new FormSync(this.context).remove(formId);
  }
}
