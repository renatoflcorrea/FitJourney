// GERADO a partir de contracts/fitjourney-export-v1.schema.json — mantenha idêntico (teste em BackupTests).
// Para mudar o contrato: edite o JSON em contracts/, copie aqui e suba schemaVersion se quebrar compatibilidade.

enum BackupSchema {
    static let exportV1 = #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://fitjourney.app/contracts/fitjourney-export-v1.schema.json",
      "title": "FitJourneyExport",
      "description": "Exportação completa do FitJourney (v1): backup/restauração e interoperabilidade (HealthProject, ChatGPT, Android). Pacote .fitjourney = zip com data.json (este documento) + media/<arquivo>; ou só data.json. Datas ISO-8601 com fuso; decimais como número; enums como rawValue estável; opcional ausente ou null = não informado (nunca zero). IDs são UUIDs estáveis preservados na importação. Campos desconhecidos são ignorados (adições compatíveis na v1); mudança incompatível = schemaVersion 2. Nunca contém segredos (chaves de API).",
      "$comment": "Mapeamento para o HealthProject (Especificacao.md §2.4/§2.5): programs → TrainingPlanVersion (routines → PlannedSession; routines[].exercises → PlannedExercise com repsMin/repsMax de repTarget e intendedLoad = currentLoad ?? initialLoad); sessions → WorkoutSession (exercises[].sets achatados → ExerciseSet; order = posição; exerciseId = exerciseID; kind warmup/feeder → warmup, demais → working; painLevel/painLocation → PainReport); load → Load (weight → convention total, bodyweight com value > 0 → added, < 0 → assistance); effort → Effort; nutritionPlans → NutritionPlanVersion; foodEntries → FoodEntry (estimation informed → informedTotal, estimated/ai → estimated). Ausente = não informado nos dois sistemas. Importação: o provedor e a URL do Coach (preferences.coachProvider.provider/customBaseURL) nunca são aplicados — o destino da chave de API não pode vir de um arquivo; só modelos por provedor e customContextTokens. Links de vídeo com usuário/senha na URL são descartados na exportação e na importação. createdAt/updatedAt acima de agora + 1 dia são limitados na importação; IDs repetidos valem só na 1ª ocorrência.",
      "x-healthProjectMapping": {
        "programs": "TrainingPlanVersion",
        "programs[].routines": "PlannedSession",
        "programs[].routines[].exercises": "PlannedExercise",
        "sessions": "WorkoutSession",
        "sessions[].exercises[].sets": "ExerciseSet",
        "exercises": "Exercise",
        "nutritionPlans": "NutritionPlanVersion",
        "foodEntries": "FoodEntry",
        "$defs/load": "Load",
        "$defs/effort": "Effort"
      },
      "type": "object",
      "required": [
        "format",
        "schemaVersion",
        "exportedAt",
        "app",
        "options",
        "exercises",
        "programs",
        "sessions",
        "nutritionPlans",
        "foodEntries",
        "waterLogs",
        "foods",
        "preferences",
        "media"
      ],
      "properties": {
        "format": {
          "type": "string",
          "enum": [
            "fitjourney-export"
          ],
          "description": "Sempre \"fitjourney-export\"."
        },
        "schemaVersion": {
          "type": "integer",
          "minimum": 1,
          "description": "Versão maior do contrato. Maior que a suportada → o app pede atualização.",
          "maximum": 2147483647
        },
        "exportedAt": {
          "$ref": "#/$defs/dateTime"
        },
        "app": {
          "$ref": "#/$defs/appInfo"
        },
        "options": {
          "$ref": "#/$defs/options"
        },
        "exercises": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/exercise"
          },
          "maxItems": 200000
        },
        "programs": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/program"
          },
          "maxItems": 200000
        },
        "sessions": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/session"
          },
          "maxItems": 200000
        },
        "nutritionPlans": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/nutritionPlan"
          },
          "maxItems": 200000
        },
        "foodEntries": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/foodEntry"
          },
          "maxItems": 200000
        },
        "waterLogs": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/waterLog"
          },
          "maxItems": 200000
        },
        "foods": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/food"
          },
          "maxItems": 200000
        },
        "coachConversations": {
          "anyOf": [
            {
              "type": "array",
              "items": {
                "$ref": "#/$defs/conversation"
              },
              "maxItems": 1000
            },
            {
              "type": "null"
            }
          ],
          "description": "Ausente/null = exportado sem conversas."
        },
        "coachProfile": {
          "anyOf": [
            {
              "$ref": "#/$defs/coachProfile"
            },
            {
              "type": "null"
            }
          ]
        },
        "preferences": {
          "$ref": "#/$defs/preferences"
        },
        "media": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/mediaFile"
          },
          "maxItems": 200000
        }
      },
      "$defs": {
        "uuid": {
          "type": "string",
          "format": "uuid",
          "pattern": "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
        },
        "dateTime": {
          "type": "string",
          "format": "date-time",
          "pattern": "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d+)?(Z|[+-]\\d{2}:?\\d{2})$",
          "description": "ISO-8601 com fuso (Z ou ±hh:mm), milissegundos opcionais."
        },
        "muscleGroup": {
          "type": "string",
          "enum": [
            "chest",
            "back",
            "lowerBack",
            "traps",
            "shoulders",
            "biceps",
            "triceps",
            "forearms",
            "abs",
            "obliques",
            "quads",
            "hamstrings",
            "glutes",
            "calves",
            "adductors",
            "abductors",
            "fullBody",
            "cardio"
          ]
        },
        "equipment": {
          "type": "string",
          "enum": [
            "barbell",
            "dumbbell",
            "machine",
            "cable",
            "bodyweight",
            "band",
            "kettlebell",
            "cardio",
            "other"
          ]
        },
        "laterality": {
          "type": "string",
          "enum": [
            "bilateral",
            "unilateral"
          ]
        },
        "measurementKind": {
          "type": "string",
          "enum": [
            "repsAndLoad",
            "repsOnly",
            "isometric",
            "timeOrDistance"
          ]
        },
        "programGoal": {
          "type": "string",
          "enum": [
            "hypertrophy",
            "strength",
            "endurance",
            "fatLoss",
            "conditioning",
            "rehabilitation",
            "other"
          ]
        },
        "scheduleMode": {
          "type": "string",
          "enum": [
            "free",
            "sequential",
            "weekly"
          ]
        },
        "programOrigin": {
          "type": "string",
          "enum": [
            "manual",
            "ai",
            "imported",
            "duplicated"
          ]
        },
        "weekday": {
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
        "setKind": {
          "type": "string",
          "enum": [
            "warmup",
            "feeder",
            "working",
            "dropSet",
            "restPause",
            "toFailure",
            "backOff"
          ]
        },
        "sessionStatus": {
          "type": "string",
          "enum": [
            "inProgress",
            "completed",
            "discarded"
          ]
        },
        "sessionExerciseStatus": {
          "type": "string",
          "enum": [
            "pending",
            "inProgress",
            "completed",
            "partial",
            "skipped"
          ]
        },
        "skipReason": {
          "type": "string",
          "enum": [
            "equipmentBusy",
            "pain",
            "time",
            "other"
          ]
        },
        "weightUnit": {
          "type": "string",
          "enum": [
            "kg",
            "lb"
          ]
        },
        "nutritionPlanAuthor": {
          "type": "string",
          "enum": [
            "me",
            "nutritionist",
            "ai"
          ]
        },
        "foodUnit": {
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
        "estimationSource": {
          "type": "string",
          "enum": [
            "informed",
            "estimated",
            "ai"
          ]
        },
        "mealStatus": {
          "type": "string",
          "enum": [
            "pending",
            "done",
            "adjusted",
            "skipped"
          ]
        },
        "messageRole": {
          "type": "string",
          "enum": [
            "system",
            "user",
            "assistant",
            "tool"
          ]
        },
        "messageState": {
          "type": "string",
          "enum": [
            "streaming",
            "complete",
            "stopped",
            "failed"
          ]
        },
        "aiProvider": {
          "type": "string",
          "enum": [
            "openAI",
            "anthropic",
            "openRouter",
            "custom",
            "chatGPT"
          ]
        },
        "videoProvider": {
          "type": "string",
          "enum": [
            "youtube",
            "vimeo",
            "other"
          ]
        },
        "coachSex": {
          "type": "string",
          "enum": [
            "female",
            "male",
            "other"
          ]
        },
        "coachLevel": {
          "type": "string",
          "enum": [
            "beginner",
            "intermediate",
            "advanced"
          ]
        },
        "repTarget": {
          "type": "object",
          "required": [
            "kind"
          ],
          "properties": {
            "kind": {
              "type": "string",
              "enum": [
                "fixed",
                "range",
                "amrap"
              ],
              "description": "fixed usa reps; range usa min e max; amrap = máximo possível."
            },
            "reps": {
              "type": [
                "integer",
                "null"
              ],
              "minimum": 1,
              "maximum": 10000
            },
            "min": {
              "type": [
                "integer",
                "null"
              ],
              "minimum": 1,
              "maximum": 10000
            },
            "max": {
              "type": [
                "integer",
                "null"
              ],
              "minimum": 1,
              "maximum": 10000
            }
          }
        },
        "load": {
          "type": "object",
          "description": "HealthProject: Load{value, unit, convention}; weight → total, bodyweight com value > 0 → added, < 0 → assistance.",
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
              "minimum": -1000,
              "maximum": 10000
            },
            "unit": {
              "$ref": "#/$defs/weightUnit"
            }
          }
        },
        "effort": {
          "type": "object",
          "description": "HealthProject: Effort (.rir/.rpe).",
          "required": [
            "kind",
            "value"
          ],
          "properties": {
            "kind": {
              "type": "string",
              "enum": [
                "rir",
                "rpe"
              ]
            },
            "value": {
              "type": "number",
              "minimum": 0,
              "maximum": 10
            }
          }
        },
        "cardio": {
          "type": "object",
          "required": [],
          "properties": {
            "durationSeconds": {
              "type": [
                "integer",
                "null"
              ],
              "minimum": 0,
              "maximum": 604800
            },
            "distanceMeters": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 1000000
            },
            "level": {
              "type": [
                "integer",
                "null"
              ],
              "minimum": 0,
              "maximum": 1000
            },
            "speedKmh": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 100
            },
            "inclinePercent": {
              "type": [
                "number",
                "null"
              ],
              "minimum": -50,
              "maximum": 100
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
        },
        "media": {
          "type": "object",
          "required": [
            "kind"
          ],
          "properties": {
            "kind": {
              "type": "string",
              "enum": [
                "image",
                "localVideo",
                "externalVideo"
              ],
              "description": "image/localVideo: arquivo em media/<fileName>; externalVideo: link."
            },
            "fileName": {
              "type": [
                "string",
                "null"
              ],
              "maxLength": 500
            },
            "thumbnailFileName": {
              "type": [
                "string",
                "null"
              ],
              "maxLength": 500
            },
            "url": {
              "type": [
                "string",
                "null"
              ],
              "maxLength": 2048
            },
            "provider": {
              "anyOf": [
                {
                  "$ref": "#/$defs/videoProvider"
                },
                {
                  "type": "null"
                }
              ]
            },
            "videoID": {
              "type": [
                "string",
                "null"
              ],
              "maxLength": 500
            }
          }
        },
        "nutrients": {
          "type": "object",
          "description": "Valores da quantidade registrada. Ausente/null = não informado (nunca zero).",
          "required": [],
          "properties": {
            "kcal": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 100000
            },
            "protein": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 10000
            },
            "carbs": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 10000
            },
            "fat": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 10000
            },
            "fiber": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 10000
            }
          }
        },
        "exercise": {
          "type": "object",
          "description": "Exercício do catálogo (do usuário ou embutido, referenciado por catalogKey). HealthProject: Exercise.",
          "required": [
            "id",
            "createdAt",
            "updatedAt",
            "name",
            "primaryMuscles",
            "secondaryMuscles",
            "equipment",
            "laterality",
            "measurementKind",
            "media",
            "isBuiltIn",
            "notes"
          ],
          "properties": {
            "id": {
              "$ref": "#/$defs/uuid"
            },
            "createdAt": {
              "$ref": "#/$defs/dateTime"
            },
            "updatedAt": {
              "$ref": "#/$defs/dateTime"
            },
            "name": {
              "type": "string",
              "maxLength": 500
            },
            "primaryMuscles": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/muscleGroup"
              },
              "maxItems": 18
            },
            "secondaryMuscles": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/muscleGroup"
              },
              "maxItems": 18
            },
            "equipment": {
              "$ref": "#/$defs/equipment"
            },
            "laterality": {
              "$ref": "#/$defs/laterality"
            },
            "measurementKind": {
              "$ref": "#/$defs/measurementKind"
            },
            "media": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/media"
              },
              "maxItems": 20
            },
            "isBuiltIn": {
              "type": "boolean"
            },
            "catalogKey": {
              "type": [
                "string",
                "null"
              ],
              "description": "Chave estável do catálogo embutido; na importação, embutidos são casados por ela (IDs mudam entre instalações).",
              "maxLength": 500
            },
            "notes": {
              "type": "string",
              "maxLength": 10000
            },
            "defaultRestSeconds": {
              "description": "Ausente = usar o descanso padrão de Ajustes.",
              "type": "integer",
              "minimum": 0,
              "maximum": 3600
            }
          }
        },
        "setPrescription": {
          "type": "object",
          "description": "Série prescrita: initialLoad = carga ao criar/editar a ficha; currentLoad = carga atual após progressão.",
          "required": [
            "id",
            "createdAt",
            "updatedAt",
            "sortIndex",
            "kind",
            "notes"
          ],
          "properties": {
            "id": {
              "$ref": "#/$defs/uuid"
            },
            "createdAt": {
              "$ref": "#/$defs/dateTime"
            },
            "updatedAt": {
              "$ref": "#/$defs/dateTime"
            },
            "sortIndex": {
              "type": "integer",
              "minimum": -100000,
              "maximum": 100000
            },
            "kind": {
              "$ref": "#/$defs/setKind"
            },
            "repTarget": {
              "anyOf": [
                {
                  "$ref": "#/$defs/repTarget"
                },
                {
                  "type": "null"
                }
              ]
            },
            "holdSeconds": {
              "type": [
                "integer",
                "null"
              ],
              "minimum": 0,
              "maximum": 3600
            },
            "initialLoad": {
              "anyOf": [
                {
                  "$ref": "#/$defs/load"
                },
                {
                  "type": "null"
                }
              ]
            },
            "currentLoad": {
              "anyOf": [
                {
                  "$ref": "#/$defs/load"
                },
                {
                  "type": "null"
                }
              ]
            },
            "restSeconds": {
              "type": [
                "integer",
                "null"
              ],
              "minimum": 0,
              "maximum": 3600
            },
            "tempo": {
              "type": [
                "string",
                "null"
              ],
              "maxLength": 500
            },
            "effort": {
              "anyOf": [
                {
                  "$ref": "#/$defs/effort"
                },
                {
                  "type": "null"
                }
              ]
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
            },
            "notes": {
              "type": "string",
              "maxLength": 10000
            }
          }
        },
        "routineExercise": {
          "type": "object",
          "description": "exerciseID = exercises[].id deste arquivo (null = exercício removido). Mesmo groupID = bi-set/circuito. HealthProject: PlannedExercise.",
          "required": [
            "id",
            "createdAt",
            "updatedAt",
            "sortIndex",
            "notes",
            "sets"
          ],
          "properties": {
            "id": {
              "$ref": "#/$defs/uuid"
            },
            "createdAt": {
              "$ref": "#/$defs/dateTime"
            },
            "updatedAt": {
              "$ref": "#/$defs/dateTime"
            },
            "exerciseID": {
              "anyOf": [
                {
                  "$ref": "#/$defs/uuid"
                },
                {
                  "type": "null"
                }
              ]
            },
            "sortIndex": {
              "type": "integer",
              "minimum": -100000,
              "maximum": 100000
            },
            "groupID": {
              "anyOf": [
                {
                  "$ref": "#/$defs/uuid"
                },
                {
                  "type": "null"
                }
              ]
            },
            "notes": {
              "type": "string",
              "maxLength": 10000
            },
            "restSeconds": {
              "type": [
                "integer",
                "null"
              ],
              "minimum": 0,
              "maximum": 3600
            },
            "sets": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/setPrescription"
              },
              "maxItems": 100
            }
          }
        },
        "routine": {
          "type": "object",
          "description": "Ficha. HealthProject: PlannedSession.",
          "required": [
            "id",
            "createdAt",
            "updatedAt",
            "name",
            "symbol",
            "colorName",
            "weekdays",
            "sortIndex",
            "notes",
            "exercises"
          ],
          "properties": {
            "id": {
              "$ref": "#/$defs/uuid"
            },
            "createdAt": {
              "$ref": "#/$defs/dateTime"
            },
            "updatedAt": {
              "$ref": "#/$defs/dateTime"
            },
            "name": {
              "type": "string",
              "maxLength": 500
            },
            "symbol": {
              "type": "string",
              "maxLength": 500
            },
            "colorName": {
              "type": "string",
              "maxLength": 500
            },
            "weekdays": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/weekday"
              },
              "maxItems": 7
            },
            "sortIndex": {
              "type": "integer",
              "minimum": -100000,
              "maximum": 100000
            },
            "notes": {
              "type": "string",
              "maxLength": 10000
            },
            "exercises": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/routineExercise"
              },
              "maxItems": 100
            }
          }
        },
        "program": {
          "type": "object",
          "description": "Programa de treino. HealthProject: TrainingPlanVersion (startDate/endDate → validFrom/validUntil; origin → author/provenance).",
          "required": [
            "id",
            "createdAt",
            "updatedAt",
            "name",
            "goal",
            "goalText",
            "scheduleMode",
            "startDate",
            "notes",
            "isActive",
            "isArchived",
            "origin",
            "routines"
          ],
          "properties": {
            "id": {
              "$ref": "#/$defs/uuid"
            },
            "createdAt": {
              "$ref": "#/$defs/dateTime"
            },
            "updatedAt": {
              "$ref": "#/$defs/dateTime"
            },
            "name": {
              "type": "string",
              "maxLength": 500
            },
            "goal": {
              "$ref": "#/$defs/programGoal"
            },
            "goalText": {
              "type": "string",
              "maxLength": 10000
            },
            "scheduleMode": {
              "$ref": "#/$defs/scheduleMode"
            },
            "startDate": {
              "$ref": "#/$defs/dateTime"
            },
            "endDate": {
              "anyOf": [
                {
                  "$ref": "#/$defs/dateTime"
                },
                {
                  "type": "null"
                }
              ]
            },
            "notes": {
              "type": "string",
              "maxLength": 10000
            },
            "isActive": {
              "type": "boolean"
            },
            "isArchived": {
              "type": "boolean"
            },
            "origin": {
              "$ref": "#/$defs/programOrigin"
            },
            "routines": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/routine"
              },
              "maxItems": 50
            }
          }
        },
        "performedSet": {
          "type": "object",
          "description": "Série realizada com snapshot da prescrição (repTarget/plannedLoad/...). HealthProject: ExerciseSet (order = posição; kind warmup/feeder → warmup, demais → working; deviatedFromPlan derivável de load ≠ plannedLoad).",
          "required": [
            "id",
            "createdAt",
            "updatedAt",
            "sortIndex",
            "kind",
            "isCompleted",
            "edited"
          ],
          "properties": {
            "id": {
              "$ref": "#/$defs/uuid"
            },
            "createdAt": {
              "$ref": "#/$defs/dateTime"
            },
            "updatedAt": {
              "$ref": "#/$defs/dateTime"
            },
            "sortIndex": {
              "type": "integer",
              "minimum": -100000,
              "maximum": 100000
            },
            "prescriptionID": {
              "anyOf": [
                {
                  "$ref": "#/$defs/uuid"
                },
                {
                  "type": "null"
                }
              ]
            },
            "kind": {
              "$ref": "#/$defs/setKind"
            },
            "repTarget": {
              "anyOf": [
                {
                  "$ref": "#/$defs/repTarget"
                },
                {
                  "type": "null"
                }
              ]
            },
            "plannedLoad": {
              "anyOf": [
                {
                  "$ref": "#/$defs/load"
                },
                {
                  "type": "null"
                }
              ]
            },
            "targetHoldSeconds": {
              "type": [
                "integer",
                "null"
              ],
              "minimum": 0,
              "maximum": 3600
            },
            "restSeconds": {
              "type": [
                "integer",
                "null"
              ],
              "minimum": 0,
              "maximum": 3600
            },
            "cardioTarget": {
              "anyOf": [
                {
                  "$ref": "#/$defs/cardio"
                },
                {
                  "type": "null"
                }
              ]
            },
            "reps": {
              "type": [
                "integer",
                "null"
              ],
              "minimum": 0,
              "maximum": 10000
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
            "durationSeconds": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 604800
            },
            "distanceMeters": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 1000000
            },
            "isCompleted": {
              "type": "boolean"
            },
            "completedAt": {
              "anyOf": [
                {
                  "$ref": "#/$defs/dateTime"
                },
                {
                  "type": "null"
                }
              ]
            },
            "edited": {
              "type": "boolean"
            }
          }
        },
        "sessionExercise": {
          "type": "object",
          "description": "Exercício da sessão (snapshot: nome/medida copiados). painLocation/painLevel → HealthProject PainReport (ausente = não informado).",
          "required": [
            "id",
            "createdAt",
            "updatedAt",
            "name",
            "measurementKind",
            "laterality",
            "sortIndex",
            "status",
            "notes",
            "sets"
          ],
          "properties": {
            "id": {
              "$ref": "#/$defs/uuid"
            },
            "createdAt": {
              "$ref": "#/$defs/dateTime"
            },
            "updatedAt": {
              "$ref": "#/$defs/dateTime"
            },
            "exerciseID": {
              "anyOf": [
                {
                  "$ref": "#/$defs/uuid"
                },
                {
                  "type": "null"
                }
              ]
            },
            "routineExerciseID": {
              "anyOf": [
                {
                  "$ref": "#/$defs/uuid"
                },
                {
                  "type": "null"
                }
              ]
            },
            "name": {
              "type": "string",
              "maxLength": 500
            },
            "measurementKind": {
              "$ref": "#/$defs/measurementKind"
            },
            "laterality": {
              "$ref": "#/$defs/laterality"
            },
            "sortIndex": {
              "type": "integer",
              "minimum": -100000,
              "maximum": 100000
            },
            "groupID": {
              "anyOf": [
                {
                  "$ref": "#/$defs/uuid"
                },
                {
                  "type": "null"
                }
              ]
            },
            "restSeconds": {
              "type": [
                "integer",
                "null"
              ],
              "minimum": 0,
              "maximum": 3600
            },
            "status": {
              "$ref": "#/$defs/sessionExerciseStatus"
            },
            "skipReason": {
              "anyOf": [
                {
                  "$ref": "#/$defs/skipReason"
                },
                {
                  "type": "null"
                }
              ]
            },
            "skipReasonText": {
              "type": [
                "string",
                "null"
              ],
              "maxLength": 10000
            },
            "substitutedFromExerciseID": {
              "anyOf": [
                {
                  "$ref": "#/$defs/uuid"
                },
                {
                  "type": "null"
                }
              ]
            },
            "substitutedFromName": {
              "type": [
                "string",
                "null"
              ],
              "maxLength": 500
            },
            "notes": {
              "type": "string",
              "maxLength": 10000
            },
            "painLocation": {
              "type": [
                "string",
                "null"
              ],
              "maxLength": 500
            },
            "painLevel": {
              "type": [
                "integer",
                "null"
              ],
              "minimum": 0,
              "maximum": 10
            },
            "sets": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/performedSet"
              },
              "maxItems": 100
            }
          }
        },
        "session": {
          "type": "object",
          "description": "Sessão de treino. HealthProject: WorkoutSession (programID → planId, routineID → plannedSessionId, routineName → title, duração = endedAt − startedAt − accumulatedPauseSeconds). Sessões inProgress são finalizadas ou descartadas na importação.",
          "required": [
            "id",
            "createdAt",
            "updatedAt",
            "routineName",
            "startedAt",
            "status",
            "notes",
            "accumulatedPauseSeconds",
            "exercises"
          ],
          "properties": {
            "id": {
              "$ref": "#/$defs/uuid"
            },
            "createdAt": {
              "$ref": "#/$defs/dateTime"
            },
            "updatedAt": {
              "$ref": "#/$defs/dateTime"
            },
            "routineID": {
              "anyOf": [
                {
                  "$ref": "#/$defs/uuid"
                },
                {
                  "type": "null"
                }
              ]
            },
            "programID": {
              "anyOf": [
                {
                  "$ref": "#/$defs/uuid"
                },
                {
                  "type": "null"
                }
              ]
            },
            "routineName": {
              "type": "string",
              "maxLength": 500
            },
            "startedAt": {
              "$ref": "#/$defs/dateTime"
            },
            "endedAt": {
              "anyOf": [
                {
                  "$ref": "#/$defs/dateTime"
                },
                {
                  "type": "null"
                }
              ]
            },
            "status": {
              "$ref": "#/$defs/sessionStatus"
            },
            "sessionRPE": {
              "type": [
                "integer",
                "null"
              ],
              "minimum": 1,
              "maximum": 10
            },
            "mood": {
              "type": [
                "integer",
                "null"
              ],
              "minimum": 1,
              "maximum": 5
            },
            "notes": {
              "type": "string",
              "maxLength": 10000
            },
            "healthKitWorkoutID": {
              "anyOf": [
                {
                  "$ref": "#/$defs/uuid"
                },
                {
                  "type": "null"
                }
              ]
            },
            "pausedAt": {
              "anyOf": [
                {
                  "$ref": "#/$defs/dateTime"
                },
                {
                  "type": "null"
                }
              ]
            },
            "accumulatedPauseSeconds": {
              "type": "number",
              "minimum": 0,
              "maximum": 604800
            },
            "restEndsAt": {
              "anyOf": [
                {
                  "$ref": "#/$defs/dateTime"
                },
                {
                  "type": "null"
                }
              ]
            },
            "lastActivityAt": {
              "anyOf": [
                {
                  "$ref": "#/$defs/dateTime"
                },
                {
                  "type": "null"
                }
              ]
            },
            "exercises": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/sessionExercise"
              },
              "maxItems": 100
            }
          }
        },
        "substitution": {
          "type": "object",
          "required": [
            "id",
            "name",
            "quantity",
            "unit",
            "nutrients",
            "notes"
          ],
          "properties": {
            "id": {
              "$ref": "#/$defs/uuid"
            },
            "name": {
              "type": "string",
              "maxLength": 500
            },
            "quantity": {
              "type": "number",
              "minimum": 0,
              "maximum": 100000
            },
            "unit": {
              "$ref": "#/$defs/foodUnit"
            },
            "nutrients": {
              "$ref": "#/$defs/nutrients"
            },
            "notes": {
              "type": "string",
              "maxLength": 10000
            }
          }
        },
        "mealItem": {
          "type": "object",
          "required": [
            "id",
            "createdAt",
            "updatedAt",
            "name",
            "quantity",
            "unit",
            "nutrients",
            "notes",
            "sortIndex",
            "substitutions"
          ],
          "properties": {
            "id": {
              "$ref": "#/$defs/uuid"
            },
            "createdAt": {
              "$ref": "#/$defs/dateTime"
            },
            "updatedAt": {
              "$ref": "#/$defs/dateTime"
            },
            "name": {
              "type": "string",
              "maxLength": 500
            },
            "quantity": {
              "type": "number",
              "minimum": 0,
              "maximum": 100000
            },
            "unit": {
              "$ref": "#/$defs/foodUnit"
            },
            "nutrients": {
              "$ref": "#/$defs/nutrients"
            },
            "notes": {
              "type": "string",
              "maxLength": 10000
            },
            "sortIndex": {
              "type": "integer",
              "minimum": -100000,
              "maximum": 100000
            },
            "substitutions": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/substitution"
              },
              "maxItems": 30
            }
          }
        },
        "meal": {
          "type": "object",
          "required": [
            "id",
            "createdAt",
            "updatedAt",
            "name",
            "minutesFromMidnight",
            "reminderEnabled",
            "sortIndex",
            "notes",
            "items"
          ],
          "properties": {
            "id": {
              "$ref": "#/$defs/uuid"
            },
            "createdAt": {
              "$ref": "#/$defs/dateTime"
            },
            "updatedAt": {
              "$ref": "#/$defs/dateTime"
            },
            "name": {
              "type": "string",
              "maxLength": 500
            },
            "minutesFromMidnight": {
              "type": "integer",
              "minimum": 0,
              "maximum": 1439,
              "description": "Horário local da refeição (independe de fuso)."
            },
            "reminderEnabled": {
              "type": "boolean"
            },
            "sortIndex": {
              "type": "integer",
              "minimum": -100000,
              "maximum": 100000
            },
            "notes": {
              "type": "string",
              "maxLength": 10000
            },
            "items": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/mealItem"
              },
              "maxItems": 100
            }
          }
        },
        "nutritionDay": {
          "type": "object",
          "required": [
            "id",
            "createdAt",
            "updatedAt",
            "name",
            "weekdays",
            "sortIndex",
            "meals"
          ],
          "properties": {
            "id": {
              "$ref": "#/$defs/uuid"
            },
            "createdAt": {
              "$ref": "#/$defs/dateTime"
            },
            "updatedAt": {
              "$ref": "#/$defs/dateTime"
            },
            "name": {
              "type": "string",
              "maxLength": 500
            },
            "weekdays": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/weekday"
              },
              "description": "Vazio = todos os dias.",
              "maxItems": 7
            },
            "sortIndex": {
              "type": "integer",
              "minimum": -100000,
              "maximum": 100000
            },
            "meals": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/meal"
              },
              "maxItems": 30
            }
          }
        },
        "nutritionTargets": {
          "type": "object",
          "required": [],
          "properties": {
            "kcal": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 100000
            },
            "protein": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 10000
            },
            "carbs": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 10000
            },
            "fat": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 10000
            },
            "fiber": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 10000
            },
            "waterMilliliters": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 20000
            }
          }
        },
        "nutritionPlan": {
          "type": "object",
          "description": "Plano alimentar. HealthProject: NutritionPlanVersion (author → autor; startDate/endDate → vigência).",
          "required": [
            "id",
            "createdAt",
            "updatedAt",
            "name",
            "goal",
            "startDate",
            "author",
            "isActive",
            "isArchived",
            "notes",
            "targets",
            "days"
          ],
          "properties": {
            "id": {
              "$ref": "#/$defs/uuid"
            },
            "createdAt": {
              "$ref": "#/$defs/dateTime"
            },
            "updatedAt": {
              "$ref": "#/$defs/dateTime"
            },
            "name": {
              "type": "string",
              "maxLength": 500
            },
            "goal": {
              "type": "string",
              "maxLength": 10000
            },
            "startDate": {
              "$ref": "#/$defs/dateTime"
            },
            "endDate": {
              "anyOf": [
                {
                  "$ref": "#/$defs/dateTime"
                },
                {
                  "type": "null"
                }
              ]
            },
            "author": {
              "$ref": "#/$defs/nutritionPlanAuthor"
            },
            "isActive": {
              "type": "boolean"
            },
            "isArchived": {
              "type": "boolean"
            },
            "notes": {
              "type": "string",
              "maxLength": 10000
            },
            "targets": {
              "$ref": "#/$defs/nutritionTargets"
            },
            "days": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/nutritionDay"
              },
              "maxItems": 14
            }
          }
        },
        "food": {
          "type": "object",
          "description": "Alimento favorito/recente (valores por porção).",
          "required": [
            "id",
            "createdAt",
            "updatedAt",
            "name",
            "servingQuantity",
            "unit",
            "nutrients",
            "isFavorite",
            "useCount",
            "estimation"
          ],
          "properties": {
            "id": {
              "$ref": "#/$defs/uuid"
            },
            "createdAt": {
              "$ref": "#/$defs/dateTime"
            },
            "updatedAt": {
              "$ref": "#/$defs/dateTime"
            },
            "name": {
              "type": "string",
              "maxLength": 500
            },
            "servingQuantity": {
              "type": "number",
              "minimum": 0,
              "maximum": 100000
            },
            "unit": {
              "$ref": "#/$defs/foodUnit"
            },
            "nutrients": {
              "$ref": "#/$defs/nutrients"
            },
            "isFavorite": {
              "type": "boolean"
            },
            "lastUsedAt": {
              "anyOf": [
                {
                  "$ref": "#/$defs/dateTime"
                },
                {
                  "type": "null"
                }
              ]
            },
            "useCount": {
              "type": "integer",
              "minimum": 0,
              "maximum": 10000000
            },
            "estimation": {
              "$ref": "#/$defs/estimationSource"
            }
          }
        },
        "foodEntry": {
          "type": "object",
          "description": "Registro alimentar; mealID null = fora da dieta. HealthProject: FoodEntry (date → at, mealName → meal, nutrients.kcal → energyKcal, estimation informed → informedTotal, estimated/ai → estimated).",
          "required": [
            "id",
            "createdAt",
            "updatedAt",
            "date",
            "name",
            "quantity",
            "unit",
            "nutrients",
            "estimation",
            "notes"
          ],
          "properties": {
            "id": {
              "$ref": "#/$defs/uuid"
            },
            "createdAt": {
              "$ref": "#/$defs/dateTime"
            },
            "updatedAt": {
              "$ref": "#/$defs/dateTime"
            },
            "date": {
              "$ref": "#/$defs/dateTime"
            },
            "mealID": {
              "anyOf": [
                {
                  "$ref": "#/$defs/uuid"
                },
                {
                  "type": "null"
                }
              ]
            },
            "mealName": {
              "type": [
                "string",
                "null"
              ],
              "maxLength": 500
            },
            "name": {
              "type": "string",
              "maxLength": 500
            },
            "quantity": {
              "type": "number",
              "minimum": 0,
              "maximum": 100000
            },
            "unit": {
              "$ref": "#/$defs/foodUnit"
            },
            "nutrients": {
              "$ref": "#/$defs/nutrients"
            },
            "estimation": {
              "$ref": "#/$defs/estimationSource"
            },
            "mealStatus": {
              "anyOf": [
                {
                  "$ref": "#/$defs/mealStatus"
                },
                {
                  "type": "null"
                }
              ]
            },
            "notes": {
              "type": "string",
              "maxLength": 10000
            },
            "plannedItemID": {
              "anyOf": [
                {
                  "$ref": "#/$defs/uuid"
                },
                {
                  "type": "null"
                }
              ]
            }
          }
        },
        "waterLog": {
          "type": "object",
          "required": [
            "id",
            "createdAt",
            "updatedAt",
            "date",
            "milliliters"
          ],
          "properties": {
            "id": {
              "$ref": "#/$defs/uuid"
            },
            "createdAt": {
              "$ref": "#/$defs/dateTime"
            },
            "updatedAt": {
              "$ref": "#/$defs/dateTime"
            },
            "date": {
              "$ref": "#/$defs/dateTime"
            },
            "milliliters": {
              "type": "number",
              "minimum": 0,
              "maximum": 20000
            }
          }
        },
        "message": {
          "type": "object",
          "required": [
            "id",
            "createdAt",
            "updatedAt",
            "role",
            "content",
            "state",
            "sortIndex",
            "toolResultIsError"
          ],
          "properties": {
            "id": {
              "$ref": "#/$defs/uuid"
            },
            "createdAt": {
              "$ref": "#/$defs/dateTime"
            },
            "updatedAt": {
              "$ref": "#/$defs/dateTime"
            },
            "role": {
              "$ref": "#/$defs/messageRole"
            },
            "content": {
              "type": "string",
              "maxLength": 200000
            },
            "reasoning": {
              "type": [
                "string",
                "null"
              ],
              "maxLength": 200000
            },
            "state": {
              "$ref": "#/$defs/messageState"
            },
            "failureReason": {
              "type": [
                "string",
                "null"
              ],
              "maxLength": 10000
            },
            "sortIndex": {
              "type": "integer",
              "minimum": -100000,
              "maximum": 100000
            },
            "modelID": {
              "type": [
                "string",
                "null"
              ],
              "maxLength": 500
            },
            "promptTokens": {
              "type": [
                "integer",
                "null"
              ],
              "minimum": 0,
              "maximum": 100000000
            },
            "completionTokens": {
              "type": [
                "integer",
                "null"
              ],
              "minimum": 0,
              "maximum": 100000000
            },
            "toolCalls": {
              "description": "JSON opaco do app ([ToolCall])."
            },
            "reasoningBlocks": {
              "description": "JSON opaco do app ([ReasoningBlock])."
            },
            "toolCallID": {
              "type": [
                "string",
                "null"
              ],
              "maxLength": 500
            },
            "toolName": {
              "type": [
                "string",
                "null"
              ],
              "maxLength": 500
            },
            "toolResultIsError": {
              "type": "boolean"
            },
            "proposal": {
              "description": "JSON opaco do app (CoachProposal)."
            }
          }
        },
        "conversation": {
          "type": "object",
          "required": [
            "id",
            "createdAt",
            "updatedAt",
            "title",
            "titleIsUserEdited",
            "isArchived",
            "messages"
          ],
          "properties": {
            "id": {
              "$ref": "#/$defs/uuid"
            },
            "createdAt": {
              "$ref": "#/$defs/dateTime"
            },
            "updatedAt": {
              "$ref": "#/$defs/dateTime"
            },
            "title": {
              "type": "string",
              "maxLength": 500
            },
            "titleIsUserEdited": {
              "type": "boolean"
            },
            "provider": {
              "type": [
                "string",
                "null"
              ],
              "maxLength": 500
            },
            "modelID": {
              "type": [
                "string",
                "null"
              ],
              "maxLength": 500
            },
            "isArchived": {
              "type": "boolean"
            },
            "messages": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/message"
              },
              "maxItems": 5000
            }
          }
        },
        "coachProfile": {
          "type": "object",
          "description": "Perfil do Coach (sem chaves). sharing/consentedAt são informativos: a importação nunca concede compartilhamento com o provedor de IA.",
          "required": [
            "sharing"
          ],
          "properties": {
            "age": {
              "type": [
                "integer",
                "null"
              ],
              "minimum": 0,
              "maximum": 130
            },
            "sex": {
              "anyOf": [
                {
                  "$ref": "#/$defs/coachSex"
                },
                {
                  "type": "null"
                }
              ]
            },
            "heightCm": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 300
            },
            "weightKg": {
              "type": [
                "number",
                "null"
              ],
              "minimum": 0,
              "maximum": 700
            },
            "level": {
              "anyOf": [
                {
                  "$ref": "#/$defs/coachLevel"
                },
                {
                  "type": "null"
                }
              ]
            },
            "goal": {
              "type": [
                "string",
                "null"
              ],
              "maxLength": 10000
            },
            "restrictions": {
              "type": [
                "string",
                "null"
              ],
              "maxLength": 10000
            },
            "equipment": {
              "type": [
                "string",
                "null"
              ],
              "maxLength": 10000
            },
            "daysPerWeek": {
              "type": [
                "integer",
                "null"
              ],
              "minimum": 0,
              "maximum": 7
            },
            "minutesPerSession": {
              "type": [
                "integer",
                "null"
              ],
              "minimum": 0,
              "maximum": 1440
            },
            "foodPreferences": {
              "type": [
                "string",
                "null"
              ],
              "maxLength": 10000
            },
            "sharing": {
              "type": "object",
              "required": [
                "profile",
                "workouts",
                "nutrition",
                "health"
              ],
              "properties": {
                "profile": {
                  "type": "boolean"
                },
                "workouts": {
                  "type": "boolean"
                },
                "nutrition": {
                  "type": "boolean"
                },
                "health": {
                  "type": "boolean"
                }
              }
            },
            "consentedAt": {
              "anyOf": [
                {
                  "$ref": "#/$defs/dateTime"
                },
                {
                  "type": "null"
                }
              ]
            }
          }
        },
        "coachProvider": {
          "type": "object",
          "description": "Configuração não secreta do Coach (a chave de API fica só no Keychain e nunca é exportada). Na importação, provider e customBaseURL são ignorados (informativos); entram só models e customContextTokens.",
          "required": [
            "provider",
            "models"
          ],
          "properties": {
            "provider": {
              "$ref": "#/$defs/aiProvider"
            },
            "models": {
              "type": "object",
              "description": "Modelo escolhido por provedor (chave = aiProvider).",
              "additionalProperties": {
                "type": "string",
                "maxLength": 500
              }
            },
            "customBaseURL": {
              "type": [
                "string",
                "null"
              ],
              "maxLength": 2048
            },
            "customContextTokens": {
              "type": [
                "integer",
                "null"
              ],
              "minimum": 0,
              "maximum": 10000000
            }
          }
        },
        "preferences": {
          "type": "object",
          "description": "Preferências não secretas.",
          "required": [],
          "properties": {
            "weightUnit": {
              "anyOf": [
                {
                  "$ref": "#/$defs/weightUnit"
                },
                {
                  "type": "null"
                }
              ]
            },
            "coachProvider": {
              "anyOf": [
                {
                  "$ref": "#/$defs/coachProvider"
                },
                {
                  "type": "null"
                }
              ]
            }
          }
        },
        "mediaFile": {
          "type": "object",
          "required": [
            "fileName",
            "included"
          ],
          "properties": {
            "fileName": {
              "type": "string",
              "maxLength": 500
            },
            "byteCount": {
              "type": [
                "integer",
                "null"
              ],
              "minimum": 0,
              "maximum": 4294967295
            },
            "included": {
              "type": "boolean",
              "description": "O arquivo está em media/<fileName> do pacote .fitjourney."
            }
          }
        },
        "appInfo": {
          "type": "object",
          "required": [
            "name",
            "version",
            "build",
            "platform",
            "timeZone",
            "locale"
          ],
          "properties": {
            "name": {
              "type": "string",
              "maxLength": 500
            },
            "version": {
              "type": "string",
              "maxLength": 500
            },
            "build": {
              "type": "string",
              "maxLength": 500
            },
            "platform": {
              "type": "string",
              "maxLength": 500
            },
            "timeZone": {
              "type": "string",
              "description": "Fuso do aparelho na exportação (IANA).",
              "maxLength": 500
            },
            "locale": {
              "type": "string",
              "maxLength": 500
            }
          }
        },
        "options": {
          "type": "object",
          "required": [
            "includesMedia",
            "includesCoachConversations"
          ],
          "properties": {
            "includesMedia": {
              "type": "boolean"
            },
            "includesCoachConversations": {
              "type": "boolean"
            }
          }
        }
      }
    }
    """#

    /// Enums do contrato (`$defs/<nome>.enum`) — conferidos contra os `allCases` do app nos testes.
    static let enumNames = ["muscleGroup", "equipment", "laterality", "measurementKind", "programGoal", "scheduleMode", "programOrigin", "weekday", "setKind", "sessionStatus", "sessionExerciseStatus", "skipReason", "weightUnit", "nutritionPlanAuthor", "foodUnit", "estimationSource", "mealStatus", "messageRole", "messageState", "aiProvider", "videoProvider", "coachSex", "coachLevel"]
}
