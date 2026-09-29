/// Model selection contract used by the 3.14.3 web composer. Provider IDs and
/// model IDs are separate wire fields; model IDs can themselves contain '/'.
class ModelSelection {
  final String providerId;
  final String modelId;
  final String? reasoningLevel;

  const ModelSelection(this.providerId, this.modelId, [this.reasoningLevel]);

  static ModelSelection? fromJson(Object? value) {
    if (value is! Map ||
        value['providerId'] is! String ||
        value['modelId'] is! String) return null;
    final options = value['options'];
    return ModelSelection(value['providerId'], value['modelId'],
        options is Map ? options['reasoningLevel'] as String? : null);
  }

  static ModelSelection? fromValue(String? value, [String? thought]) {
    if (value == null) return null;
    final slash = value.indexOf('/');
    if (slash <= 0 || slash == value.length - 1) return null;
    return ModelSelection(
        value.substring(0, slash), value.substring(slash + 1), thought);
  }

  String get value => '$providerId/$modelId';

  Map<String, dynamic> toJson() => {
        'providerId': providerId,
        'modelId': modelId,
        if (reasoningLevel != null)
          'options': {'reasoningLevel': reasoningLevel},
      };
}

class SelectableModel {
  final String providerId;
  final String providerName;
  final String modelId;
  final List<String> reasoningLevels;

  SelectableModel(Map provider, Map model)
      : providerId = provider['providerId'] as String,
        providerName = '${provider['providerName'] ?? provider['providerId']}',
        modelId = model['modelId'] as String,
        reasoningLevels = List<String>.from(model['config']?['optionSpecs']
                ?['reasoningLevel']?['values'] ??
            const []);

  String get value => '$providerId/$modelId';

  // Web's Ew(): choosing a model selects its last advertised reasoning level.
  ModelSelection get defaultSelection => ModelSelection(providerId, modelId,
      reasoningLevels.isEmpty ? null : reasoningLevels.last);
}

class ModelSelectionView {
  final int revision;
  final List<SelectableModel> models;
  final ModelSelection? preferredSelection;
  final ModelSelection? effectiveSelection;
  final String? selectionIssue;

  ModelSelectionView(Map raw)
      : revision = (raw['revision'] as num).toInt(),
        models = [
          for (final provider in (raw['providers'] as List).whereType<Map>())
            for (final model in (provider['models'] as List).whereType<Map>())
              SelectableModel(provider, model),
        ],
        preferredSelection = ModelSelection.fromJson(raw['preferredSelection']),
        effectiveSelection = ModelSelection.fromJson(raw['effectiveSelection']),
        selectionIssue = raw['selectionIssue'] as String?;

  SelectableModel? model(String? value) {
    for (final model in models) {
      if (model.value == value) return model;
    }
    return null;
  }

  bool supports(ModelSelection? selection) =>
      selection != null &&
      (model(selection.value)
              ?.reasoningLevels
              .contains(selection.reasoningLevel) ??
          false);

  ModelSelection requireEffectiveSelection() {
    if (selectionIssue != null || !supports(effectiveSelection)) {
      throw StateError(
          '请选择可用的模型和思考等级 (${selectionIssue ?? 'selection-invalid'})');
    }
    return effectiveSelection!;
  }
}
