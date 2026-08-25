select *
from table(snowflake.information_schema.login_history_by_user('<username>', result_limit=>50))
order by event_timestamp desc;

alter user <username> set mins_to_unlock = 0;
