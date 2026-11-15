// GERADO a partir de contracts/food-log-draft-v1.schema.json — mantenha idêntico ao arquivo (teste em MealLogTests).

extension DraftSchemas {
    static let foodLogDraftV1 = #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://fitjourney.app/contracts/food-log-draft-v1.schema.json",
      "title": "FoodLogDraft",
      "description": "Rascunho curto de registro de refeições estimado pela IA a partir de texto e/ou fotos (FitJourney). Valores são estimativas; nada é salvo sem revisão do usuário. Macros em gramas; desconhecido = null (nunca 0).",
      "type": "object",
      "additionalProperties": false,
      "required": [
        "status",
        "reason",
        "meals",
        "notSeen",
        "questions"
      ],
      "properties": {
        "status": {
          "type": "string",
          "enum": [
            "ok",
            "no_food",
            "unreadable"
          ],
          "description": "ok; no_food (a foto não mostra comida); unreadable (foto ou texto ilegível)."
        },
        "reason": {
          "type": [
            "string",
            "null"
          ],
          "description": "Motivo curto (até 200 caracteres) quando status não é ok; senão null."
        },
        "meals": {
          "type": "array",
          "maxItems": 8,
          "items": {
            "$ref": "#/$defs/meal"
          }
        },
        "notSeen": {
          "type": "array",
          "maxItems": 10,
          "items": {
            "type": "string"
          },
          "description": "O que costuma faltar numa foto e não foi contado (ex.: óleo de preparo, bebida)."
        },
        "questions": {
          "type": "array",
          "maxItems": 10,
          "items": {
            "$ref": "#/$defs/question"
          },
          "description": "Dúvidas que mudam a estimativa (ex.: tamanho não informado), com respostas rápidas."
        }
      },
      "$defs": {
        "meal": {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "slot",
            "label",
            "time",
            "plannedMealId",
            "asPlanned",
            "items"
          ],
          "properties": {
            "slot": {
              "type": "string",
              "enum": [
                "breakfast",
                "morning_snack",
                "lunch",
                "afternoon_snack",
                "dinner",
                "supper",
                "other"
              ]
            },
            "label": {
              "type": [
                "string",
                "null"
              ],
              "description": "Nome da refeição como o usuário disse (até 80 caracteres)."
            },
            "time": {
              "type": [
                "string",
                "null"
              ],
              "pattern": "^([01][0-9]|2[0-3]):[0-5][0-9]$",
              "description": "Horário HH:MM se dito; null se não."
            },
            "plannedMealId": {
              "type": [
                "string",
                "null"
              ],
              "description": "id da refeição do plano enviado, se corresponder; null sem plano ou sem correspondência."
            },
            "asPlanned": {
              "type": "boolean",
              "description": "true se o usuário disse que comeu exatamente o que estava no plano."
            },
            "items": {
              "type": "array",
              "maxItems": 20,
              "items": {
                "$ref": "#/$defs/item"
              }
            }
          }
        },
        "item": {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "name",
            "quantity",
            "unit",
            "kcal",
            "kcalMin",
            "kcalMax",
            "protein",
            "carbs",
            "fat",
            "fiber",
            "confidence",
            "note",
            "plannedItemId"
          ],
          "properties": {
            "name": {
              "type": "string",
              "description": "Alimento (até 80 caracteres)."
            },
            "quantity": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 100000,
              "description": "Quantidade estimada na unidade; null se não der para estimar."
            },
            "unit": {
              "type": "string",
              "enum": [
                "grams",
                "milliliters",
                "unit",
                "tablespoon",
                "cup",
                "slice",
                "serving"
              ]
            },
            "kcal": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 10000
            },
            "kcalMin": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 10000
            },
            "kcalMax": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 10000
            },
            "protein": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 1000
            },
            "carbs": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 1000
            },
            "fat": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 1000
            },
            "fiber": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 1000
            },
            "confidence": {
              "type": "string",
              "enum": [
                "high",
                "medium",
                "low"
              ]
            },
            "note": {
              "type": [
                "string",
                "null"
              ],
              "description": "Motivo curto da dúvida quando a confiança não é high."
            },
            "plannedItemId": {
              "type": [
                "string",
                "null"
              ],
              "description": "id do item do plano correspondente, se houver."
            }
          }
        },
        "question": {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "mealIndex",
            "itemIndex",
            "text",
            "options"
          ],
          "properties": {
            "mealIndex": {
              "type": [
                "integer",
                "null"
              ],
              "minimum": 0,
              "maximum": 7
            },
            "itemIndex": {
              "type": [
                "integer",
                "null"
              ],
              "minimum": 0,
              "maximum": 19
            },
            "text": {
              "type": "string",
              "description": "Pergunta curta (ex.: \"Qual o tamanho do copo?\")."
            },
            "options": {
              "type": "array",
              "maxItems": 4,
              "items": {
                "type": "string"
              },
              "description": "Respostas rápidas (ex.: \"200 ml\", \"300 ml\", \"500 ml\")."
            }
          }
        }
      }
    }
    """#
}
