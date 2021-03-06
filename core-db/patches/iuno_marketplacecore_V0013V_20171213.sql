﻿--#######################################################################################################
--TRUMPF Werkzeugmaschinen GmbH & Co KG
--TEMPLATE FOR DATABASE PATCHES, HOT FIXES and SCHEMA CHANGES
--Author: Marcel Ely Gomes
--CreateAt: 2017-09-13
--Version: 00.00.01 (Initial)
--#######################################################################################################
-- READ THE INSTRUCTIONS BEFORE CONTINUE - USE ONLY PatchDBTool to deploy patches to existing Databases
-- Describe your patch here
-- Patch Description: 
-- 	1) Why is this Patch necessary?
-- 	2) Which Git Issue Number is this patch solving?
-- 	3) Which changes are going to be done?
-- PATCH FILE NAME - THIS IS MANDATORY
-- iuno_<databasename>_V<patchnumber>V_<creation date>.sql
-- PatchNumber Format: 00000 whereas each new Patch increase the patchnumber by 1
-- Example: iuno_marketplacecore_V00001V_20170913.sql
--#######################################################################################################
-- PUT YOUR STATEMENTS HERE:
-- 	1) Why is this Patch necessary? 
-- 	2) Which Git Issue Number is this patch solving? 
--	#138
-- 	3) Which changes are going to be done? 
--	Update SetComponent and GetTechnologyDataByParams. Not all Input variables are obligatory
--: Run Patches
------------------------------------------------------------------------------------------------
--##############################################################################################
-- Write into the patch table: patchname, patchnumber, patchdescription and start time
--##############################################################################################
DO
$$
	DECLARE
		PatchName varchar		 	 := 'iuno_marketplacecore_V00013V_20171213';
		PatchNumber int 		 	 := 0013;
		PatchDescription varchar 	 := 'Update SetComponent and GetTechnologyDataByParams. Not all Input variables are obligatory';
        CurrentPatch int 			 := (select max(p.patchnumber) from patches p);

	BEGIN
		--INSERT START VALUES TO THE PATCH TABLE
		IF (PatchNumber <= CurrentPatch) THEN
			RAISE EXCEPTION '%', 'Wrong patch number. Please verify your patches!';
		ELSE
			INSERT INTO PATCHES (patchname, patchnumber, patchdescription, startat) VALUES (PatchName, PatchNumber, PatchDescription, now());
		END IF;
	END;
$$;
------------------------------------------------------------------------------------------------
--##############################################################################################
-- Run the patch itself and update patches table
--##############################################################################################
DO
$$
		DECLARE
			vPatchNumber int := 0013;
		BEGIN
	----------------------------------------------------------------------------------------------------------------------------------------
			CREATE OR REPLACE FUNCTION public.setcomponent(
    IN vcomponentname character varying,
    IN vcomponentparentname character varying,
    IN vcomponentdescription character varying,
    IN vattributelist text[],
    IN vtechnologylist text[],
    IN vcreatedby uuid,
    IN vroles text[])
  RETURNS TABLE(componentuuid uuid, componentname character varying, componentparentname character varying, componentparentuuid uuid, componentdescription character varying, attributelist uuid[], technologylist uuid[], createdat timestamp with time zone, createdby uuid) AS
$BODY$
	#variable_conflict use_column
      DECLARE 	vAttributeName text;
        	vTechName text;
		vCompID integer;
		vCompUUID uuid;
		vCompParentUUID uuid;
		vFunctionName varchar := 'SetComponent';
		vIsAllowed boolean := (select public.checkPermissions(vRoles, vFunctionName));

	BEGIN

	IF(vIsAllowed) THEN

		-- Is none ParentComponent -> set Root as Parent
		if (vcomponentparentname is null) then
			vcomponentparentname := 'Root';
		end if;
		vCompParentUUID := (select case when (vComponentParentName = 'Root' and not exists (select 1 from components where componentName = 'Root')) then uuid_generate_v4() else componentuuid end from components where componentname = vComponentParentName);

		-- Proof if all technologies are avaiable
		if(vTechnologyList is not null OR array_length(vTechnologyList,1)>0) then
			FOREACH vTechName in array vTechnologyList
			LOOP
				 if not exists (select technologyid from technologies where technologyname = vTechName) then
				 raise exception using
				 errcode = 'invalid_parameter_value',
				 message = 'There is no technology with TechnologyName: ' || vTechName;
				 end if;
			END LOOP;

			-- Create new Component
			perform public.createcomponent(vCompParentUUID,vComponentName, vComponentdescription, vCreatedby, vRoles);
			vCompID := (select currval('ComponentID'));
			vCompUUID := (select componentuuid from components where componentID = vCompID);

			-- Create relation from Components to TechnologyData
			perform public.CreateComponentsTechnologies(vCompUUID, vTechnologyList, vRoles);
		end if;

		-- Proof if all Attributes are avaiable
		if(vAttributeList is not null OR array_length(vAttributeList,1)>0) then
			FOREACH vAttributeName in array vAttributeList
			LOOP
				 if not exists (select attributeid from public.attributes where attributename = vAttributeName) then
					perform public.createattribute(vAttributeName,vCreatedBy, vRoles);
				 end if;
			END LOOP;

			-- Create relation from Components to Attribute
			perform public.CreateComponentsAttribute(vCompUUID, vAttributeList, vRoles);
		end if;

		-- Begin Log if success
		perform public.createlog(0,'Set Component sucessfully','SetComponent',
					'ComponentID: ' || cast(vCompID as varchar) || ', componentname: '
					|| vComponentName || ', componentdescription: ' || vComponentDescription
					|| ', CreatedBy: ' || cast(vCreatedBy as varchar));
        ELSE
		 RAISE EXCEPTION '%', 'Insufficiency rigths';
		 RETURN;
	END IF;
        -- End Log if success
        -- Return UserID
        RETURN QUERY (
			select 	co.ComponentUUID,
				co.ComponentName,
				cs.ComponentName as componentParentName,
				cs.ComponentUUID as componentParentUUID,
				co.ComponentDescription,
				array_agg(att.attributeuuid),
				array_agg(tc.technologyuuid),
				co.CreatedAt at time zone 'utc',
				vCreatedBy as CreatedBy
			from components co
			left outer join componentsattribute ca
			on co.componentid = ca.componentid
			left outer join attributes att
			on ca.attributeid = att.attributeid
			join componentstechnologies ct
			on co.componentid = ct.componentid
			join technologies tc
			on tc.technologyid = ct.technologyid
			left outer join components cs
			on co.componentparentid = cs.componentid
			where co.componentid = vCompID
			group by co.ComponentUUID, co.ComponentName, cs.ComponentName,
				cs.ComponentUUID, co.ComponentDescription, co.createdat
        );

        exception when others then
        -- Begin Log if error
        perform public.createlog(1,'ERROR: ' || SQLERRM || ' ' || SQLSTATE,'SetComponent',
                                'ComponentID: ' || cast(vCompID as varchar) || ', componentname: '
                                || vComponentName || ', componentdescription: ' || vComponentDescription
                                || ', CreatedBy: ' || cast(vCreatedBy as varchar));
        -- End Log if error
        RAISE EXCEPTION '%', 'ERROR: ' || SQLERRM || ' ' || SQLSTATE || ' at SetComponent';
        RETURN;
      END;
  $BODY$
  LANGUAGE plpgsql;

  CREATE OR REPLACE FUNCTION public.gettechnologydatabyparams(
    IN vcomponents text[],
    IN vtechnologyuuid uuid,
    IN vtechnologydataname character varying,
    IN vowneruuid uuid,
    IN vuseruuid uuid,
    IN vroles text[])
  RETURNS TABLE(result json) AS
$BODY$

	DECLARE
		vFunctionName varchar := 'GetTechnologyDataByParams';
		vIsAllowed boolean := (select public.checkPermissions(vRoles, vFunctionName));

	BEGIN

	IF(vIsAllowed) THEN

	 RETURN QUERY (	 with tg as (
				select tg.tagid, tg.tagname from tags tg
				join technologydatatags ts
				on tg.tagid = ts.tagid
				join technologydata td
				on ts.technologydataid = td.technologydataid
				join technologies tt
				on td.technologyid = tt.technologyid
				group by tg.tagid, tg.tagname
			),
			 att as (
				select ab.attributeid, attributename from components co
				join componentsattribute ca on
				co.componentid = ca.componentid
				join attributes ab on
				ca.attributeid = ab.attributeid
				join technologydatacomponents tc
				on tc.componentid = co.componentid
				group by ab.attributeid
			),
			comp as (
			select co.componentuuid, co.componentid, co.componentname,
			case when t.* is null then '[]' else array_to_json(array_agg(t.*)) end as attributes from att t
			join componentsattribute ca on t.attributeid = ca.attributeid
			right outer join components co on co.componentid = ca.componentid
			group by co.componentname, co.componentid, co.componentuuid, t.*
			),
			techData as (
				select td.technologydatauuid,
					td.technologydataname,
					tt.technologyuuid,
					td.technologydata,
					td.licensefee,
					td.productcode,
					td.technologydatadescription,
					td.technologydatathumbnail,
					td.technologydataimgref,
					td.createdat at time zone 'utc',
					td.CreatedBy,
					td.updatedat at time zone 'utc',
					td.UpdatedBy,
					array_to_json(array_agg(co.*)) componentlist
				from comp co join technologydatacomponents tc
				on co.componentid = tc.componentid
				join technologydata td on
				td.technologydataid = tc.technologydataid
				join components cm on cm.componentid = co.componentid
				join technologies tt on
				tt.technologyid = td.technologyid
				where (vOwnerUUID is null OR td.createdby = vOwnerUUID)
				and td.deleted is null
				group by td.technologydatauuid,
					td.technologydataname,
					tt.technologyuuid,
					td.technologydata,
					td.licensefee,
					td.productcode,
					td.technologydatadescription,
					td.technologydatathumbnail,
					td.technologydataimgref,
					td.createdat,
					td.createdby,
					td.updatedat,
					td.updatedby
			),
			compIn as (
				select	td.technologydataname, array_agg(componentuuid order by componentuuid asc) comp
				from components co
				join technologydatacomponents tc
				on co.componentid = tc.componentid
				join technologydata td on
				td.technologydataid = tc.technologydataid
				where td.deleted is null
				group by td.technologydataname

			)
			select array_to_json(array_agg(td.*)) from techData	td
			join compIn co on co.technologydataname = td.technologydataname
			where (co.comp::text[] <@ vComponents OR vComponents is null)
			and (vTechnologyDataName is null OR td.technologydataname = vTechnologyDataName)

		);

	ELSE
		 RAISE EXCEPTION '%', 'Insufficiency rigths';
		 RETURN;
	END IF;

	END;
		$BODY$
  LANGUAGE plpgsql;

			
	----------------------------------------------------------------------------------------------------------------------------------------
		-- UPDATE patch table status value
		UPDATE patches SET status = 'OK', endat = now() WHERE patchnumber = vPatchNumber;
		--ERROR HANDLING
		EXCEPTION WHEN OTHERS THEN
			UPDATE patches SET status = 'ERROR: ' || SQLERRM || ' ' || SQLSTATE || 'while creating patch.'	WHERE patchnumber = vPatchNumber;	 
		 RETURN;
	END;
$$; 