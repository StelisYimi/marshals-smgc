-- Rol Starter: una cuenta por starter, creada por Gerencia en Equipo
alter type rol_usuario add value if not exists 'starter' before 'capitan';
