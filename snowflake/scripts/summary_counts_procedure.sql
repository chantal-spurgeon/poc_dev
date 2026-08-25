CREATE or replace procedure load_sdmp_prod_db.dod_decode.GENERATE_SUMMARY_COUNTS("rid" STRING)
RETURNS VARCHAR
LANGUAGE javascript
AS
$$
//Array created to house insert statements.
var insert_statements = [];

// create for the following inserts
var create_statement = `SELECT 'insert into load_sdmp_prod_db.dod_decode.summary_counts select release_id,''' \
|| book_name \
|| ''' ,' \
|| book_name \
|| ',''' \
|| display_column_name \
|| ''', sum(case when prdm='||'''Y'||''' then 1 else 0 end) as "prod_count", sum(case when prdm<>'||'''Y'||''' then 1 else 0 end) as "non_prod_count", count(*) , ' \
|| conversion_calculation \
|| ' conversion_calculation ,current_date() load_Date, current_time() load_time, current_user() load_user from load_sdmp_prod_db.sdmp_license_owner.license where release_id = ` + rid + ` group by release_id,' \
|| book_name \
|| CASE WHEN book_name = 'N2CTY' THEN ', ST' else '' end \
|| ';' \
from dod_decode.data_dictionary \
where conversion_calculation is not null \
and book_name not IN ('RDOLLARS' \
,'BAVGDOLL' \
,'BAVGOFDL' \
,'BAVGONDL' \
,'BOFDOLLR' \
,'BONDOLLR' \
,'BTOTLDOL' \
,'A_NOC19' \
,'ZINCDEC' \
,'IBHHID' \
,'C210AUTO' \
,'C210MAH' \
,'ZP42' \
,'BOFORDER' \
,'BONORDER' \
,'BTOTLORD' \
,'CALAGE' \
,'N2TSC' \
,'RORDERS' \
,'C210HMI' \
,'C210EBI' \
,'C210HVA' \
,'A_CALAGE' \
,'NAH19' \
,'NOC19' \
,'NPH19' \
,'Z4HMVALU' \
,'A_CSAG' \
,'LNVLRTIO' \
,'N2BC' \
,'PD_MORTASSUM_AMT' \
,'PD_FMORT1' \
,'HMVLADD' \
,'SCF' \
,'C210KSES'
,'N2TBG' \
,'EAREA' \
,'TINS' \
,'DOBCCYY' \
,'FEFFYRBL' \
,'FYEARBLT' \
,'VH1YEAR' \
,'VH2YEAR' \
,'VH3YEAR' \
,'A_CDRG' \
,'BDOC' \
,'CACD' \
,'CNBC' \
,'CPPD' \
,'FSALDATE' \
,'ISDT' \
,'VH1PURDT' \
,'VH2PURDT' \
,'VH3PURDT' \
,'PD_MORTDT' \
,'PD_MORTDUEDT' \
,'ISDATEON' \
,'CDB1' \
,'CDB2' \
,'CDB3' \
,'CDB4' \
,'DOBDD' \
,'EXCHG' \
,'DOBMM' \
,'EPHONE' \
,'BLOFORDR' \
,'BLONORDR' \
,'BLSTORDR' \
,'RORDERDT' \
,'CDOB' \
,'CRRT' \
,'PD_LENDCD' \
,'PD_LENDNME' \
,'PD_LSQFT' \
,'PD_MORTTRM' \
,'PD_ORIGAPN' \
,'FMORTTRM' \
,'C210MAH' \
,'C210EBI' \
,'C210HVA' \
,'C210HMI') \
order by book_name;`

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
		        
return 'Summary Counts Complete.';

$$;
