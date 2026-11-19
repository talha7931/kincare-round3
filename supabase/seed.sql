-- Lookup data only. Do not add users or caregiver/elderly profiles.
insert into public.ACTIVITY_TYPES(stable_key, name, description)
values
  ('memory_decks', 'Memory Decks', 'Personalised family-photo reminiscence'),
  ('odd_one_out', 'Odd One Out', 'Find the item that differs'),
  ('everyday_object_sorting', 'Everyday Object Sorting', 'Place familiar objects into categories')
ON CONFLICT (stable_key) do update set
  name = excluded.name,
  description = excluded.description;
