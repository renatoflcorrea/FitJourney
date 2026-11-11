import Foundation

// Saneamento do documento antes de importar: datas de registro no futuro distante e IDs repetidos.

extension BackupV1.Document {
    /// - `createdAt`/`updatedAt` limitados a `now + 1 dia` (um relógio adiantado não vence toda mesclagem).
    /// - IDs repetidos (em qualquer nível) valem só na primeira ocorrência.
    func sanitizedForImport(now: Date = .now) -> BackupV1.Document {
        let ceiling = now.addingTimeInterval(24 * 3600)
        var seen = Set<UUID>()
        func keep(_ id: UUID) -> Bool { seen.insert(id).inserted }
        func clamp(_ date: Date) -> Date { min(date, ceiling) }

        var d = self
        d.exercises = d.exercises.filter { keep($0.id) }.map { var e = $0; e.createdAt = clamp(e.createdAt); e.updatedAt = clamp(e.updatedAt); return e }
        d.programs = d.programs.filter { keep($0.id) }.map { program in
            var p = program
            p.createdAt = clamp(p.createdAt); p.updatedAt = clamp(p.updatedAt)
            p.routines = p.routines.filter { keep($0.id) }.map { routine in
                var r = routine
                r.createdAt = clamp(r.createdAt); r.updatedAt = clamp(r.updatedAt)
                r.exercises = r.exercises.filter { keep($0.id) }.map { exercise in
                    var e = exercise
                    e.createdAt = clamp(e.createdAt); e.updatedAt = clamp(e.updatedAt)
                    e.sets = e.sets.filter { keep($0.id) }.map { var s = $0; s.createdAt = clamp(s.createdAt); s.updatedAt = clamp(s.updatedAt); return s }
                    return e
                }
                return r
            }
            return p
        }
        d.sessions = d.sessions.filter { keep($0.id) }.map { session in
            var s = session
            s.createdAt = clamp(s.createdAt); s.updatedAt = clamp(s.updatedAt)
            s.exercises = s.exercises.filter { keep($0.id) }.map { exercise in
                var e = exercise
                e.createdAt = clamp(e.createdAt); e.updatedAt = clamp(e.updatedAt)
                e.sets = e.sets.filter { keep($0.id) }.map { var x = $0; x.createdAt = clamp(x.createdAt); x.updatedAt = clamp(x.updatedAt); return x }
                return e
            }
            return s
        }
        d.nutritionPlans = d.nutritionPlans.filter { keep($0.id) }.map { plan in
            var p = plan
            p.createdAt = clamp(p.createdAt); p.updatedAt = clamp(p.updatedAt)
            p.days = p.days.filter { keep($0.id) }.map { day in
                var dd = day
                dd.createdAt = clamp(dd.createdAt); dd.updatedAt = clamp(dd.updatedAt)
                dd.meals = dd.meals.filter { keep($0.id) }.map { meal in
                    var m = meal
                    m.createdAt = clamp(m.createdAt); m.updatedAt = clamp(m.updatedAt)
                    m.items = m.items.filter { keep($0.id) }.map { var i = $0; i.createdAt = clamp(i.createdAt); i.updatedAt = clamp(i.updatedAt); return i }
                    return m
                }
                return dd
            }
            return p
        }
        d.foodEntries = d.foodEntries.filter { keep($0.id) }.map { var e = $0; e.createdAt = clamp(e.createdAt); e.updatedAt = clamp(e.updatedAt); return e }
        d.waterLogs = d.waterLogs.filter { keep($0.id) }.map { var w = $0; w.createdAt = clamp(w.createdAt); w.updatedAt = clamp(w.updatedAt); return w }
        d.foods = d.foods.filter { keep($0.id) }.map { var f = $0; f.createdAt = clamp(f.createdAt); f.updatedAt = clamp(f.updatedAt); return f }
        d.coachConversations = d.coachConversations.map { list in
            list.filter { keep($0.id) }.map { conversation in
                var c = conversation
                c.createdAt = clamp(c.createdAt); c.updatedAt = clamp(c.updatedAt)
                c.messages = c.messages.filter { keep($0.id) }.map { var m = $0; m.createdAt = clamp(m.createdAt); m.updatedAt = clamp(m.updatedAt); return m }
                return c
            }
        }
        return d
    }
}
