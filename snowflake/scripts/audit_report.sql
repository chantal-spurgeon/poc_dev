use role accountadmin;

use role dod_sdmp_prod_owner_role;


use role dod_sdmp_prod_owner_role;


CREATE or replace procedure DOD_SDMP_PROD_DB.DOD_LICENSE_100_PCT_DATA.current_audit_totals("cust_name" STRING)
RETURNS VARCHAR
LANGUAGE javascript
COMMENT = 'For use with release runs once License load and DECODE is complete.'
AS
$$

//clear existing data in case of rerun

var delete_stmt = `delete from DOD_SDMP_PROD_DB.DOD_LICENSE_100_PCT_DATA.audit_report where client_name = '` + cust_name + `' and release_id = \
(select distinct release_id from dod_sdmp_prod_db.dod_license_100_pct_current.` + cust_name + `_license);`

var delete_sql = snowflake.createStatement({sqlText: delete_stmt});

var delete_exec = delete_sql.execute(); 

//set totals all rows in view, all prod rows in view, and all non_prod rows in view

var view_total = 0;
var prod_total = 0;
var non_prod_total = 0;

var total_stmt = `select count(*) as all_rows from dod_sdmp_prod_db.dod_license_100_pct_current.` + cust_name + `_license;`
var prod_stmt = `select count(*) as prod_rows from dod_sdmp_prod_db.dod_license_100_pct_current.` + cust_name + `_license where PRDM='Y';`
var non_prod_stmt = `select count(*) as non_prod_rows from dod_sdmp_prod_db.dod_license_100_pct_current.` + cust_name + `_license where PRDM<>'Y';`

try {
    var rs = getResultSet(total_stmt);
    if (rs.next()) {
        var view_total = rs.getColumnValue("ALL_ROWS");
    } else {
        return "Error: all count query failed.";
    }
}
catch(err) {
    return "Error: " + err.message;
}

try {
    var rs = getResultSet(prod_stmt);
    if (rs.next()) {
        var prod_total = rs.getColumnValue("PROD_ROWS");
    } else {
        return "Error: prod count query failed.";
    }
}
catch(err) {
    return "Error: " + err.message;
}

try {
    var rs = getResultSet(non_prod_stmt);
    if (rs.next()) {
        var non_prod_total = rs.getColumnValue("NON_PROD_ROWS");
    } else {
        return "Error: non-prod count query failed.";
    }
}
catch(err) {
    return "Error: " + err.message;
}


//Array created to house insert statements.
var insert_statements = [];

// create for the following inserts

var create_statement = `SELECT 'insert into DOD_SDMP_PROD_DB.DOD_LICENSE_100_PCT_DATA.audit_report select '||'''` + cust_name + `'||''' ,''' \
|| book_name \
|| ''' ,'  \
|| licensing_audit \
|| ' as "description" , count(*) as "full_count", to_number("full_count"/` + view_total + `*100,6,2),count_if(prdm='||'''Y'||''') as "prod_count", '\
|| 'CASE WHEN "prod_count" = 0 then 0 else to_number("prod_count"/` + prod_total + `*100,6,2) end,' \
|| ' count_if(prdm<>'||'''Y'||''') as "non_prod_count", CASE WHEN "non_prod_count" = 0 then 0 else to_number("non_prod_count"/` + non_prod_total +`*100,6,2) end, '''||field_name||''', '\
|| CASE WHEN special_rollup = 'Y' then '''''' else book_name end\
|| '' \
|| ',release_id from dod_sdmp_prod_db.dod_license_100_pct_current.'||'` + cust_name + `'||'_license group by release_id, '\
|| CASE WHEN special_rollup = 'Y' then '"description"' else book_name end \
|| CASE WHEN book_name = 'N2CTY' THEN ', ST' else '' end \
|| ';' \
from load_sdmp_prod_db.dod_decode.data_dictionary \
where licensing_audit is not null \
and book_name IN (select column_name from dod_sdmp_prod_db.information_schema.columns where table_name = '` + cust_name + `_LICENSE' and table_schema = 'DOD_LICENSE_100_PCT_CURRENT') \
order by ordinal_position;`

var istmt_sql = snowflake.createStatement({sqlText: create_statement});

var istmt = istmt_sql.execute();

//load user values from table into Array, we will be looping through the array to execute the each statement

while (istmt.next()){
    var insert_to_run = istmt.getColumnValue(1);
    insert_statements.push(insert_to_run);
                  }
//run for each insert statement                 

for (var i = 0; i < insert_statements.length; i++) {
        
        snowflake.execute({ sqlText: insert_statements[i] });
        
        }
        
//set null values to BLANK

var blank_stmt = `update DOD_SDMP_PROD_DB.DOD_LICENSE_100_PCT_DATA.audit_report set description = 'Blank' where description is null;`

var blank_sql = snowflake.createStatement({sqlText: blank_stmt});

var blank_exec = blank_sql.execute(); 
		        
return 'Audit Report genererated successfully.';

//get results function

function getResultSet(sql){
    cmd1 = {sqlText: sql};
    stmt = snowflake.createStatement(cmd1);
    var rs;
    rs = stmt.execute();
    return rs;
}

$$;


------------------------------------------


CREATE or replace procedure DOD_SDMP_PROD_DB.DOD_LICENSE_100_PCT_DATA.next_audit_totals("cust_name" STRING)
RETURNS VARCHAR
LANGUAGE javascript
COMMENT = 'For use with release runs once License load and DECODE is complete.'
AS
$$

//clear existing data in case of rerun

var delete_stmt = `delete from DOD_SDMP_PROD_DB.DOD_LICENSE_100_PCT_DATA.audit_report where client_name = '` + cust_name + `' and release_id = \
(select distinct release_id from dod_sdmp_prod_db.dod_license_100_pct_next.` + cust_name + `_license);`

var delete_sql = snowflake.createStatement({sqlText: delete_stmt});

var delete_exec = delete_sql.execute(); 

//set totals all rows in view, all prod rows in view, and all non_prod rows in view

var view_total = 0;
var prod_total = 0;
var non_prod_total = 0;

var total_stmt = `select count(*) as all_rows from dod_sdmp_prod_db.dod_license_100_pct_next.` + cust_name + `_license;`
var prod_stmt = `select count(*) as prod_rows from dod_sdmp_prod_db.dod_license_100_pct_next.` + cust_name + `_license where PRDM='Y';`
var non_prod_stmt = `select count(*) as non_prod_rows from dod_sdmp_prod_db.dod_license_100_pct_next.` + cust_name + `_license where PRDM<>'Y';`

try {
    var rs = getResultSet(total_stmt);
    if (rs.next()) {
        var view_total = rs.getColumnValue("ALL_ROWS");
    } else {
        return "Error: all count query failed.";
    }
}
catch(err) {
    return "Error: " + err.message;
}

try {
    var rs = getResultSet(prod_stmt);
    if (rs.next()) {
        var prod_total = rs.getColumnValue("PROD_ROWS");
    } else {
        return "Error: prod count query failed.";
    }
}
catch(err) {
    return "Error: " + err.message;
}

try {
    var rs = getResultSet(non_prod_stmt);
    if (rs.next()) {
        var non_prod_total = rs.getColumnValue("NON_PROD_ROWS");
    } else {
        return "Error: non-prod count query failed.";
    }
}
catch(err) {
    return "Error: " + err.message;
}


//Array created to house insert statements.
var insert_statements = [];

// create for the following inserts

var create_statement = `SELECT 'insert into DOD_SDMP_PROD_DB.DOD_LICENSE_100_PCT_DATA.audit_report select '||'''` + cust_name + `'||''' ,''' \
|| book_name \
|| ''' ,'  \
|| licensing_audit \
|| ' as "description" , count(*) as "full_count", to_number("full_count"/` + view_total + `*100,6,2),count_if(prdm='||'''Y'||''') as "prod_count", '\
|| 'CASE WHEN "prod_count" = 0 then 0 else to_number("prod_count"/` + prod_total + `*100,6,2) end,' \
|| ' count_if(prdm<>'||'''Y'||''') as "non_prod_count", CASE WHEN "non_prod_count" = 0 then 0 else to_number("non_prod_count"/` + non_prod_total +`*100,6,2) end, '''||field_name||''', '\
|| CASE WHEN special_rollup = 'Y' then '''''' else book_name end\
|| '' \
|| ',release_id from dod_sdmp_prod_db.dod_license_100_pct_next.'||'` + cust_name + `'||'_license group by release_id, '\
|| CASE WHEN special_rollup = 'Y' then '"description"' else book_name end \
|| CASE WHEN book_name = 'N2CTY' THEN ', ST' else '' end \
|| ';' \
from load_sdmp_prod_db.dod_decode.data_dictionary \
where licensing_audit is not null \
and book_name IN (select column_name from dod_sdmp_prod_db.information_schema.columns where table_name = '` + cust_name + `_LICENSE' and table_schema = 'DOD_LICENSE_100_PCT_NEXT') \
order by ordinal_position;`

var istmt_sql = snowflake.createStatement({sqlText: create_statement});

var istmt = istmt_sql.execute();

//load user values from table into Array, we will be looping through the array to execute the each statement

while (istmt.next()){
    var insert_to_run = istmt.getColumnValue(1);
    insert_statements.push(insert_to_run);
                  }
//run for each insert statement                 

for (var i = 0; i < insert_statements.length; i++) {
        
        snowflake.execute({ sqlText: insert_statements[i] });
        
        }
        
//set null values to BLANK

var blank_stmt = `update DOD_SDMP_PROD_DB.DOD_LICENSE_100_PCT_DATA.audit_report set description = 'Blank' where description is null;`

var blank_sql = snowflake.createStatement({sqlText: blank_stmt});

var blank_exec = blank_sql.execute(); 
		        
return 'Audit Report genererated successfully.';

//get results function

function getResultSet(sql){
    cmd1 = {sqlText: sql};
    stmt = snowflake.createStatement(cmd1);
    var rs;
    rs = stmt.execute();
    return rs;
}

$$;

-- How to use in code

call DOD_SDMP_PROD_DB.DOD_LICENSE_100_PCT_DATA.current_audit_totals(<customer_name>);
