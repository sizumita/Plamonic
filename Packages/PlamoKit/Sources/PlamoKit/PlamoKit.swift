// PlamoKit: native PLaMo 3 Translate (MLX) inference.
//
// - PlamoTokenizer: port of tokenization_plamo.py
// - PlamoPromptBuilder: PFML3 prompts identical to chat_template.jinja
// - Plamo3Model / PlamoGenerator: port of modeling_plamo_mlx.py with greedy decoding
// - PlamoModelStore: Hugging Face download and on-disk layout
// - PlamoTranslationEngine: actor that owns loaded models and serializes all MLX work
