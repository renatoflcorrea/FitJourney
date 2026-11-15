import Foundation

// Cópias exatas de `contracts/program-import-v2.schema.json` e `nutrition-import-v2.schema.json` (teste de identidade).
// Geradas a partir do v1: séries agrupadas (treino) e itens enxutos (dieta).
extension ImportSchemas {
    static let programImportV2 = #"""
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://fitjourney.app/contracts/program-import-v2.schema.json",
  "title": "ProgramImportV2",
  "description": "Extração compacta de programa de treino a partir de arquivos — FitJourney v2. Séries iguais e seguidas vão num grupo só (count); o app expande para o program-import-v1. Copie o que está escrito; não invente. Campo desconhecido = null.",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "name",
    "goal",
    "goalText",
    "scheduleMode",
    "durationWeeks",
    "notes",
    "confidence",
    "source",
    "routines",
    "ambiguities"
  ],
  "properties": {
    "name": {
      "type": [
        "string",
        "null"
      ],
      "description": "Nome do programa se escrito; null se não houver."
    },
    "goal": {
      "type": [
        "string",
        "null"
      ],
      "enum": [
        "hypertrophy",
        "strength",
        "endurance",
        "fatLoss",
        "conditioning",
        "rehabilitation",
        "other",
        null
      ],
      "description": "Objetivo quando indicado."
    },
    "goalText": {
      "type": [
        "string",
        "null"
      ],
      "description": "Objetivo como escrito."
    },
    "scheduleMode": {
      "type": [
        "string",
        "null"
      ],
      "enum": [
        "free",
        "sequential",
        "weekly",
        null
      ],
      "description": "weekly se o arquivo liga fichas a dias da semana; sequential se é rodízio A→B→C; null se não indica."
    },
    "durationWeeks": {
      "type": [
        "integer",
        "null"
      ],
      "minimum": 1,
      "maximum": 52
    },
    "notes": {
      "type": [
        "string",
        "null"
      ],
      "description": "O que estava ambíguo, ilegível ou foi inferido (curto). null se nada."
    },
    "confidence": {
      "type": "string",
      "enum": [
        "high",
        "medium",
        "low"
      ],
      "description": "Confiança na leitura: high = legível e explícito; medium = inferido do contexto; low = ilegível, ambíguo ou adivinhado."
    },
    "source": {
      "anyOf": [
        {
          "$ref": "#/$defs/source"
        },
        {
          "type": "null"
        }
      ]
    },
    "routines": {
      "type": "array",
      "maxItems": 12,
      "items": {
        "$ref": "#/$defs/routine"
      },
      "description": "Todas as fichas detectadas."
    },
    "ambiguities": {
      "type": "array",
      "maxItems": 20,
      "items": {
        "$ref": "#/$defs/ambiguity"
      }
    }
  },
  "$defs": {
    "source": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "file",
        "page"
      ],
      "properties": {
        "file": {
          "type": "string",
          "description": "Nome do arquivo exatamente como no rótulo [Arquivo: …]."
        },
        "page": {
          "type": [
            "integer",
            "null"
          ],
          "minimum": 1,
          "description": "Página (1-based) quando houver; null em imagens/texto."
        }
      },
      "description": "Onde o item foi lido."
    },
    "ambiguity": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "path",
        "question",
        "options"
      ],
      "properties": {
        "path": {
          "type": "string",
          "description": "Caminho do item, ex.: routines[0].exercises[2].sets."
        },
        "question": {
          "type": "string",
          "description": "Pergunta curta em pt-BR para o usuário."
        },
        "options": {
          "type": "array",
          "maxItems": 6,
          "items": {
            "type": "string"
          },
          "description": "Respostas possíveis (vazio = resposta livre)."
        }
      },
      "description": "Dúvida que só o usuário resolve (ex.: \"3x12\" = 3 séries de 12 ou 12 séries de 3?)."
    },
    "routine": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "name",
        "symbol",
        "weekdays",
        "notes",
        "confidence",
        "source",
        "exercises"
      ],
      "properties": {
        "name": {
          "type": [
            "string",
            "null"
          ],
          "description": "Nome da ficha como escrito (ex.: \"Peito e tríceps\"); null se não houver."
        },
        "symbol": {
          "type": [
            "string",
            "null"
          ],
          "description": "Letra da ficha quando escrita (A, B, C…)."
        },
        "weekdays": {
          "type": "array",
          "maxItems": 7,
          "items": {
            "type": "string",
            "enum": [
              "monday",
              "tuesday",
              "wednesday",
              "thursday",
              "friday",
              "saturday",
              "sunday"
            ]
          },
          "description": "Dias da semana se o arquivo indicar; senão vazio."
        },
        "notes": {
          "type": [
            "string",
            "null"
          ],
          "description": "O que estava ambíguo, ilegível ou foi inferido (curto). null se nada."
        },
        "confidence": {
          "type": "string",
          "enum": [
            "high",
            "medium",
            "low"
          ],
          "description": "Confiança na leitura: high = legível e explícito; medium = inferido do contexto; low = ilegível, ambíguo ou adivinhado."
        },
        "source": {
          "anyOf": [
            {
              "$ref": "#/$defs/source"
            },
            {
              "type": "null"
            }
          ]
        },
        "exercises": {
          "type": "array",
          "maxItems": 20,
          "items": {
            "$ref": "#/$defs/exercise"
          }
        }
      },
      "description": "Uma ficha (treino) detectada. Arquivos podem ter várias fichas diferentes: devolva uma por treino."
    },
    "exercise": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "asWritten",
        "name",
        "catalogKey",
        "restSeconds",
        "groupLabel",
        "notes",
        "confidence",
        "source",
        "setGroups"
      ],
      "properties": {
        "asWritten": {
          "type": "string",
          "description": "Nome do exercício exatamente como escrito no arquivo."
        },
        "name": {
          "type": [
            "string",
            "null"
          ],
          "description": "Nome normalizado em pt-BR (do catálogo quando casar); null se ilegível."
        },
        "catalogKey": {
          "type": [
            "string",
            "null"
          ],
          "description": "Chave do catálogo do app só quando tiver certeza; senão null."
        },
        "restSeconds": {
          "type": [
            "integer",
            "null"
          ],
          "minimum": 0,
          "maximum": 600,
          "description": "Descanso entre séries, se escrito."
        },
        "groupLabel": {
          "type": [
            "string",
            "null"
          ],
          "description": "Mesmo rótulo na mesma ficha = bi-set/tri-set/circuito."
        },
        "notes": {
          "type": [
            "string",
            "null"
          ],
          "description": "O que estava ambíguo, ilegível ou foi inferido (curto). null se nada."
        },
        "confidence": {
          "type": "string",
          "enum": [
            "high",
            "medium",
            "low"
          ],
          "description": "Confiança na leitura: high = legível e explícito; medium = inferido do contexto; low = ilegível, ambíguo ou adivinhado."
        },
        "source": {
          "anyOf": [
            {
              "$ref": "#/$defs/source"
            },
            {
              "type": "null"
            }
          ]
        },
        "setGroups": {
          "type": "array",
          "maxItems": 12,
          "items": {
            "$ref": "#/$defs/setGroup"
          },
          "description": "Séries iguais e seguidas num grupo só: \"3x12\" = um grupo com count 3 e reps \"12\". Séries diferentes (aquecimento + válidas, pirâmide) em grupos separados, na ordem."
        }
      }
    },
    "setGroup": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "count",
        "kind",
        "reps",
        "load",
        "loadAsWritten",
        "restSeconds",
        "extra",
        "notes",
        "confidence"
      ],
      "properties": {
        "count": {
          "type": "integer",
          "minimum": 1,
          "maximum": 12,
          "description": "Quantas séries iguais e seguidas."
        },
        "kind": {
          "type": [
            "string",
            "null"
          ],
          "enum": [
            "warmup",
            "feeder",
            "working",
            "dropSet",
            "restPause",
            "toFailure",
            "backOff",
            null
          ],
          "description": "Tipo da série; null = não indicado (válida)."
        },
        "reps": {
          "type": [
            "string",
            "null"
          ],
          "pattern": "^(amrap|[0-9]{1,3}(-[0-9]{1,3})?)$",
          "description": "Alvo de repetições: \"12\", faixa \"8-12\" ou \"amrap\"; null se não escrito ou se é isométrico/cardio."
        },
        "load": {
          "anyOf": [
            {
              "$ref": "#/$defs/load"
            },
            {
              "type": "null"
            }
          ]
        },
        "loadAsWritten": {
          "type": [
            "string",
            "null"
          ],
          "description": "Carga como escrita quando não foi possível converter (ex.: \"placa 7\", ilegível)."
        },
        "restSeconds": {
          "type": [
            "integer",
            "null"
          ],
          "minimum": 0,
          "maximum": 600
        },
        "extra": {
          "anyOf": [
            {
              "$ref": "#/$defs/extra"
            },
            {
              "type": "null"
            }
          ]
        },
        "notes": {
          "type": [
            "string",
            "null"
          ],
          "description": "O que estava ambíguo, ilegível ou foi inferido (curto). null se nada."
        },
        "confidence": {
          "type": "string",
          "enum": [
            "high",
            "medium",
            "low"
          ],
          "description": "Confiança na leitura: high = legível e explícito; medium = inferido do contexto; low = ilegível, ambíguo ou adivinhado."
        }
      },
      "description": "Grupo de séries idênticas."
    },
    "extra": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "holdSeconds",
        "tempo",
        "rir",
        "rpe",
        "cardio"
      ],
      "properties": {
        "holdSeconds": {
          "type": [
            "integer",
            "null"
          ],
          "minimum": 1,
          "maximum": 600,
          "description": "Sustentação (isométricos)."
        },
        "tempo": {
          "type": [
            "string",
            "null"
          ],
          "description": "Cadência, ex.: \"3-1-1-0\"."
        },
        "rir": {
          "type": [
            "integer",
            "null"
          ],
          "minimum": 0,
          "maximum": 5
        },
        "rpe": {
          "type": [
            "number",
            "null"
          ],
          "minimum": 1,
          "maximum": 10
        },
        "cardio": {
          "anyOf": [
            {
              "$ref": "#/$defs/cardio"
            },
            {
              "type": "null"
            }
          ]
        }
      },
      "description": "Campos raros (isometria, cadência, RIR/RPE, cardio). null no grupo quando nenhum estiver escrito."
    },
    "load": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind",
        "value",
        "unit"
      ],
      "properties": {
        "kind": {
          "type": "string",
          "enum": [
            "weight",
            "bodyweight"
          ],
          "description": "weight = carga absoluta; bodyweight = peso corporal com value de lastro (+) ou assistência (−)."
        },
        "value": {
          "type": "number",
          "minimum": -200,
          "maximum": 1000
        },
        "unit": {
          "type": "string",
          "enum": [
            "kg",
            "lb"
          ]
        }
      }
    },
    "cardio": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "durationSeconds",
        "distanceMeters",
        "level",
        "speedKmh",
        "inclinePercent",
        "heartRateZone"
      ],
      "properties": {
        "durationSeconds": {
          "type": [
            "integer",
            "null"
          ],
          "minimum": 1,
          "maximum": 14400
        },
        "distanceMeters": {
          "type": [
            "number",
            "null"
          ],
          "minimum": 0,
          "maximum": 100000
        },
        "level": {
          "type": [
            "integer",
            "null"
          ],
          "minimum": 0,
          "maximum": 50
        },
        "speedKmh": {
          "type": [
            "number",
            "null"
          ],
          "minimum": 0,
          "maximum": 50
        },
        "inclinePercent": {
          "type": [
            "number",
            "null"
          ],
          "minimum": -10,
          "maximum": 40
        },
        "heartRateZone": {
          "type": [
            "integer",
            "null"
          ],
          "minimum": 1,
          "maximum": 5
        }
      }
    }
  }
}
"""#

    static let nutritionImportV2 = #"""
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://fitjourney.app/contracts/nutrition-import-v2.schema.json",
  "title": "NutritionImportV2",
  "description": "Extração compacta de plano alimentar a partir de arquivos — FitJourney v2. Itens sem source (vale o da refeição) e valores nutricionais num objeto opcional; o app expande para o nutrition-import-v1. Copie o que está escrito; não invente.",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "name",
    "goal",
    "notes",
    "confidence",
    "source",
    "targets",
    "days",
    "ambiguities"
  ],
  "properties": {
    "name": {
      "type": [
        "string",
        "null"
      ],
      "description": "Nome do plano se escrito."
    },
    "goal": {
      "type": [
        "string",
        "null"
      ],
      "description": "Objetivo como escrito."
    },
    "notes": {
      "type": [
        "string",
        "null"
      ],
      "description": "O que estava ambíguo, ilegível ou foi inferido (curto). null se nada."
    },
    "confidence": {
      "type": "string",
      "enum": [
        "high",
        "medium",
        "low"
      ],
      "description": "Confiança na leitura: high = legível e explícito; medium = inferido do contexto; low = ilegível, ambíguo ou adivinhado."
    },
    "source": {
      "anyOf": [
        {
          "$ref": "#/$defs/source"
        },
        {
          "type": "null"
        }
      ]
    },
    "targets": {
      "$ref": "#/$defs/targets"
    },
    "days": {
      "type": "array",
      "maxItems": 7,
      "items": {
        "$ref": "#/$defs/day"
      },
      "description": "Variações do plano (um item se o plano é igual todo dia)."
    },
    "ambiguities": {
      "type": "array",
      "maxItems": 20,
      "items": {
        "$ref": "#/$defs/ambiguity"
      }
    }
  },
  "$defs": {
    "source": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "file",
        "page"
      ],
      "properties": {
        "file": {
          "type": "string",
          "description": "Nome do arquivo exatamente como no rótulo [Arquivo: …]."
        },
        "page": {
          "type": [
            "integer",
            "null"
          ],
          "minimum": 1,
          "description": "Página (1-based) quando houver; null em imagens/texto."
        }
      },
      "description": "Onde o item foi lido."
    },
    "ambiguity": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "path",
        "question",
        "options"
      ],
      "properties": {
        "path": {
          "type": "string",
          "description": "Caminho do item, ex.: routines[0].exercises[2].sets."
        },
        "question": {
          "type": "string",
          "description": "Pergunta curta em pt-BR para o usuário."
        },
        "options": {
          "type": "array",
          "maxItems": 6,
          "items": {
            "type": "string"
          },
          "description": "Respostas possíveis (vazio = resposta livre)."
        }
      },
      "description": "Dúvida que só o usuário resolve (ex.: \"3x12\" = 3 séries de 12 ou 12 séries de 3?)."
    },
    "targets": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kcal",
        "protein",
        "carbs",
        "fat",
        "fiber",
        "waterMilliliters",
        "confidence",
        "source"
      ],
      "properties": {
        "kcal": {
          "type": [
            "number",
            "null"
          ],
          "minimum": 0,
          "maximum": 20000
        },
        "protein": {
          "type": [
            "number",
            "null"
          ],
          "minimum": 0,
          "maximum": 2000
        },
        "carbs": {
          "type": [
            "number",
            "null"
          ],
          "minimum": 0,
          "maximum": 3000
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
          "maximum": 500
        },
        "waterMilliliters": {
          "type": [
            "number",
            "null"
          ],
          "minimum": 0,
          "maximum": 20000
        },
        "confidence": {
          "type": "string",
          "enum": [
            "high",
            "medium",
            "low"
          ],
          "description": "Confiança na leitura: high = legível e explícito; medium = inferido do contexto; low = ilegível, ambíguo ou adivinhado."
        },
        "source": {
          "anyOf": [
            {
              "$ref": "#/$defs/source"
            },
            {
              "type": "null"
            }
          ]
        }
      },
      "description": "Metas diárias quando escritas (gramas para macros); null se ausentes."
    },
    "day": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "name",
        "weekdays",
        "notes",
        "confidence",
        "source",
        "meals"
      ],
      "properties": {
        "name": {
          "type": [
            "string",
            "null"
          ],
          "description": "Nome da variação (ex.: \"Dia de treino\", \"Segunda e quarta\")."
        },
        "weekdays": {
          "type": "array",
          "maxItems": 7,
          "items": {
            "type": "string",
            "enum": [
              "monday",
              "tuesday",
              "wednesday",
              "thursday",
              "friday",
              "saturday",
              "sunday"
            ]
          },
          "description": "Dias em que vale; vazio = todos os dias ou não indicado."
        },
        "notes": {
          "type": [
            "string",
            "null"
          ],
          "description": "O que estava ambíguo, ilegível ou foi inferido (curto). null se nada."
        },
        "confidence": {
          "type": "string",
          "enum": [
            "high",
            "medium",
            "low"
          ],
          "description": "Confiança na leitura: high = legível e explícito; medium = inferido do contexto; low = ilegível, ambíguo ou adivinhado."
        },
        "source": {
          "anyOf": [
            {
              "$ref": "#/$defs/source"
            },
            {
              "type": "null"
            }
          ]
        },
        "meals": {
          "type": "array",
          "maxItems": 12,
          "items": {
            "$ref": "#/$defs/meal"
          }
        }
      }
    },
    "meal": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "name",
        "time",
        "notes",
        "confidence",
        "source",
        "items"
      ],
      "properties": {
        "name": {
          "type": [
            "string",
            "null"
          ],
          "description": "Nome da refeição (Café da manhã, Almoço…)."
        },
        "time": {
          "type": [
            "string",
            "null"
          ],
          "pattern": "^([01][0-9]|2[0-3]):[0-5][0-9]$",
          "description": "Horário HH:MM se escrito; null se não houver."
        },
        "notes": {
          "type": [
            "string",
            "null"
          ],
          "description": "O que estava ambíguo, ilegível ou foi inferido (curto). null se nada."
        },
        "confidence": {
          "type": "string",
          "enum": [
            "high",
            "medium",
            "low"
          ],
          "description": "Confiança na leitura: high = legível e explícito; medium = inferido do contexto; low = ilegível, ambíguo ou adivinhado."
        },
        "source": {
          "anyOf": [
            {
              "$ref": "#/$defs/source"
            },
            {
              "type": "null"
            }
          ]
        },
        "items": {
          "type": "array",
          "maxItems": 30,
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
        "asWritten",
        "name",
        "quantity",
        "unit",
        "macros",
        "notes",
        "confidence",
        "substitutions"
      ],
      "properties": {
        "asWritten": {
          "type": "string",
          "description": "Item exatamente como escrito (ex.: \"2 fatias pão integral\")."
        },
        "name": {
          "type": "string",
          "description": "Nome do alimento em pt-BR."
        },
        "quantity": {
          "type": [
            "number",
            "null"
          ],
          "minimum": 0,
          "maximum": 10000,
          "description": "Quantidade numérica; null se não escrita."
        },
        "unit": {
          "type": [
            "string",
            "null"
          ],
          "enum": [
            "grams",
            "milliliters",
            "unit",
            "tablespoon",
            "cup",
            "slice",
            "serving",
            null
          ]
        },
        "macros": {
          "anyOf": [
            {
              "$ref": "#/$defs/macros"
            },
            {
              "type": "null"
            }
          ]
        },
        "notes": {
          "type": [
            "string",
            "null"
          ],
          "description": "O que estava ambíguo, ilegível ou foi inferido (curto). null se nada."
        },
        "confidence": {
          "type": "string",
          "enum": [
            "high",
            "medium",
            "low"
          ],
          "description": "Confiança na leitura: high = legível e explícito; medium = inferido do contexto; low = ilegível, ambíguo ou adivinhado."
        },
        "substitutions": {
          "type": "array",
          "maxItems": 10,
          "items": {
            "$ref": "#/$defs/substitution"
          },
          "description": "Opções de troca escritas para o item."
        }
      },
      "description": "Valores nutricionais só se escritos no arquivo; não estime."
    },
    "substitution": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "name",
        "quantity",
        "unit",
        "macros",
        "notes"
      ],
      "properties": {
        "name": {
          "type": "string"
        },
        "quantity": {
          "type": [
            "number",
            "null"
          ],
          "minimum": 0,
          "maximum": 10000
        },
        "unit": {
          "type": [
            "string",
            "null"
          ],
          "enum": [
            "grams",
            "milliliters",
            "unit",
            "tablespoon",
            "cup",
            "slice",
            "serving",
            null
          ]
        },
        "macros": {
          "anyOf": [
            {
              "$ref": "#/$defs/substitutionMacros"
            },
            {
              "type": "null"
            }
          ]
        },
        "notes": {
          "type": [
            "string",
            "null"
          ],
          "description": "O que estava ambíguo, ilegível ou foi inferido (curto). null se nada."
        }
      }
    },
    "macros": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kcal",
        "protein",
        "carbs",
        "fat",
        "fiber"
      ],
      "properties": {
        "kcal": {
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
          "maximum": 500
        }
      },
      "description": "Valores nutricionais só se escritos no arquivo; null no item quando nenhum estiver escrito."
    },
    "substitutionMacros": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kcal",
        "protein",
        "carbs",
        "fat"
      ],
      "properties": {
        "kcal": {
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
        }
      },
      "description": "Valores da substituição só se escritos no arquivo (sem fibra: o app não guarda fibra nas trocas); null quando nenhum estiver escrito."
    }
  }
}
"""#
}
