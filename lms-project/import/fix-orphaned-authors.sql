-- Reinstates the 15 "authors" rows that import-tables.sh's NOT-NULL-skip
-- logic dropped (blank "name", which the model requires). Turns out 10 of
-- these 15 ARE referenced by real books.author_id (NOT NULL, so it can't
-- just be nulled out the way organization_branches.city_id was) — dropping
-- them broke the books_author_id_fkey constraint. See README.md's
-- "Correction" note and fixes/NOTES.md for the full story.
--
-- Run against organization_old_restore (or organization, whichever you're
-- using): psql -h localhost -U postgres -d organization_old_restore -f fix-orphaned-authors.sql
INSERT INTO "authors" (id, name, status, is_deleted, "createdAt", "updatedAt") VALUES
('21161d3c-6a1c-46a6-9ee6-baef44dc8f01', 'Unknown Author', 1, false, '2024-02-28 17:34:57.14+00', '2024-02-28 17:34:57.14+00'),
('58ddce02-ce55-4cc5-8b93-06215d193860', 'Unknown Author', 1, false, '2024-02-28 17:38:01.726+00', '2024-02-28 17:38:01.726+00'),
('e7f488f7-24f3-43a7-89ae-234d09266a5a', 'Unknown Author', 1, false, '2024-02-28 17:40:38.873+00', '2024-02-28 17:40:38.873+00'),
('03bbd6aa-191e-46b7-a425-9182f38117b3', 'Unknown Author', 1, false, '2024-02-29 07:58:25.699+00', '2024-02-29 07:58:25.699+00'),
('34fe5ff9-3bd9-47f5-af42-89edc83f71b7', 'Unknown Author', 1, false, '2024-02-29 11:27:30.126+00', '2024-02-29 11:27:30.126+00'),
('f4cf7c07-ea45-4095-8ee7-6c7236eed53e', 'Unknown Author', 1, false, '2024-02-29 14:33:11.071+00', '2024-02-29 14:33:11.071+00'),
('9e9397e3-4af2-480e-8d10-b5be55dcda57', 'Unknown Author', 1, false, '2024-03-11 05:35:35.1+00', '2024-03-11 05:35:35.1+00'),
('b17b0246-9ccb-4b2f-847e-c87f9f583565', 'Unknown Author', 1, false, '2024-03-11 05:58:16.906+00', '2024-03-11 05:58:16.906+00'),
('f1bd4734-9932-41f7-9491-7f3ec330890b', 'Unknown Author', 1, false, '2024-03-11 08:00:17.529+00', '2024-03-11 08:00:17.529+00'),
('464d1e06-38a4-43b3-b24b-7d44a0538f2e', 'Unknown Author', 1, false, '2024-03-11 13:57:57.202+00', '2024-03-11 13:57:57.202+00'),
('3d30900d-ab4c-4c36-bbd5-8df58318f67b', 'Unknown Author', 1, false, '2024-03-13 09:40:46.103+00', '2024-03-13 09:40:46.103+00'),
('eece42b7-884a-41f6-ae1f-54bd9fe301a8', 'Unknown Author', 1, false, '2024-03-13 09:41:13.997+00', '2024-03-13 09:41:13.997+00'),
('1cb82261-5644-4c4d-a36a-74a3b2e05358', 'Unknown Author', 1, false, '2024-03-13 09:41:38.583+00', '2024-03-13 09:41:38.583+00'),
('7c8fba68-aa88-4e2e-8aeb-03a99a9f682a', 'Unknown Author', 1, false, '2024-03-18 08:19:53.076+00', '2024-03-18 08:19:53.076+00'),
('bf67194e-a153-47a2-bf44-6dbc6ed7aad7', 'Unknown Author', 1, false, '2024-03-28 09:06:05.906+00', '2024-03-28 09:06:05.906+00')
ON CONFLICT (id) DO NOTHING;
