library(targets)
library(tarchetypes)
library(future)

# Config ------------------------------------------------------------------

# Set target-specific options such as packages.
tar_option_set(packages = c("dplyr", "statnipokladna", "here", "readxl",
                            "janitor", "curl", "httr", "stringr", "config",
                            "dplyr", "purrrow", "future", "arrow", "tidyr",
                            "ragg", "magrittr", "czso", "lubridate", "writexl",
                            "readr", "purrr", "pointblank", "tarchetypes",
                            "details", "forcats", "ggplot2", "gt"),
               # debug = "compiled_macro_sum_quarterly",
               imports = c("purrrow", "statnipokladna"),
)

options(crayon.enabled = TRUE,
        scipen = 100,
        czso.dest_dir = "~/czso_data",
        yaml.eval.expr = TRUE)

future::plan(multicore)

source("R/utils.R")
source("R/functions.R")

cnf <- config::get(config = "default")
names(cnf) <- paste0("c_", names(cnf))
list2env(cnf, envir = .GlobalEnv)

# tar_renv(path = "packages.R")

# ESIF data ---------------------------------------------------------------


## Public project data -----------------------------------------------------

t_public_list <- list(
  tar_download(ef_pubxls, c_ef_pubxls_url,
               here::here("data-input/ef_publish.xls")),
  tar_target(ef_pub, read_pubxls(ef_pubxls))
)


## Custom MS sestavy -------------------------------------------------------

t_sestavy <- list(
  # finanční pokrok
  tar_target(efs_fin, load_efs_fin(c_sest_dir, c_sest_xlsx_fin)),
  # seznam ŽOPek
  tar_target(efs_zop, load_efs_zop(c_sest_dir, c_sest_xlsx_zop)),
  # základní info o projektech
  # obsahuje ekonomické kategorie intervence, SC atd.
  tar_target(efs_prj, load_efs_prj(c_sest_dir, c_sest_xlsx_prj)),
  # oblasti intervence
  tar_target(efs_obl, load_efs_obl(c_sest_dir, c_sest_xlsx_obl)),
  # výřes základních informací o projektech
  tar_target(efs_prj_basic, efs_prj %>% select(-starts_with("katekon_"),
                                               -starts_with("sc_")) %>%
               distinct()),
  # specifické cíle
  # bez rozpadu na kategorie intervence
  # protože ten je v datech nepřiznaný
  tar_target(efs_prj_sc, efs_prj %>%
               select(prj_id, starts_with("sc_")) %>%
               distinct()),
  # kategorie intervence, bez rozpadu na SC
  tar_target(efs_prj_kat, efs_prj %>%
               select(prj_id, starts_with("katekon_")) %>%
               distinct() %>%
               group_by(prj_id) %>%
               mutate(katekon_podil = 1/n())),
  # sečíst ŽOP za každý projekt po letech
  tar_target(efs_zop_annual, summarise_zop(efs_zop, quarterly = FALSE)),
  # a po čtvrtletích
  tar_target(efs_zop_quarterly, summarise_zop(efs_zop, quarterly = TRUE)),
  # načíst PRV
  tar_target(efs_prv, load_prv(c_prv_data_path, cis_kraj)),
  # posčítat platby PRV za projekt po letech
  tar_target(efs_prv_annual, summarise_prv(efs_prv, quarterly = FALSE)),
  # a PRV po čtvrtletích
  tar_target(efs_prv_quarterly, summarise_prv(efs_prv, quarterly = TRUE))
)

## Geographically disaggregated (obce) ESIF data ---------------------------

t_esif_obce <- list(
  tar_file(esif_obce, c_ef_obce_arrowdir),
  # vazby ZÚJ a obcí, abychom mohli ZÚJ v datech
  # převést na obce
  tar_target(zuj_obec, get_zuj_obec()),
  # číselník krajů pro vložení kódu kraje v PRV
  tar_target(cis_kraj, czso::czso_get_codelist("cis100")),
  # populace obcí pro vážení projektů mezi kraji
  tar_target(pop_obce, get_stats_pop_obce(c_czso_pop_table_id)),
  # spočítat podíly krajů na každém projektu
  tar_target(eo_kraj, summarise_geo_by_kraj(esif_obce, pop_obce, zuj_obec))
)


## Modeling categorisations ------------------------------------------------

## dodané a ručně upravené vazby
t_cats <- list(
  # QUEST kategorie <=> oblast intervence
  tar_target(macrocat_quest, load_macrocat_quest(c_mc_xlsx_q, prv = FALSE)),
  # QUEST a HERMIN <=> typ operace v PRV (u PRV máme HERMIN a QUEST v jedné tabulce)
  tar_target(macrocat_prv, load_macrocat_quest(c_mc_xlsx_prv, prv = TRUE)),
  # HERMIN podkategorie QUEST AIS <=> kategorie intervence
  tar_target(macrocat_hermin, load_macrocat_hermin(c_mc_xlsx_h)),
  # rozkategorizovat všechna data
  tar_target(efs_macrocat, add_macrocat(efs_prj_kat, efs_obl,
                                        macrocat_quest,
                                        macrocat_hermin,
                                        efs_prj_sc,
                                        ef_hier)),
  tar_target(prv_macrocat_fin,
             add_macrocat_prv(efs_prv_quarterly, macrocat_prv))
)


## N+3 forecast -----------------------------------------------------------

t_nplus3 <- list(
  tar_target(efs_nplus3_remainder, calculate_nplus3_remainder(efs_fin)),
  tar_target(efs_nplus3_durations, project_nplus3_durations(efs_prj)),
  tar_target(efs_nplus3_fin,
             project_nplus3_spend(efs_nplus3_remainder, efs_nplus3_durations)),
  tar_target(efs_macrocat_nplus3, add_financials(efs_macrocat, efs_nplus3_fin)),
  tar_target(efs_macrocat_nplus3_reg, add_regions(efs_macrocat_nplus3, eo_kraj))
)

t_nplus3_sum <- list(
  tar_target(macro_sum_nplus3,
             summarise_macro(efs_macrocat_nplus3,
                             prv = NULL,
                             quarterly = FALSE, regional = FALSE,
                             dt_var = dt_nplus3_rok)),
  tar_target(macro_sum_nplus3_reg,
             summarise_macro(efs_macrocat_nplus3_reg,
                             prv = NULL,
                             quarterly = FALSE, regional = TRUE,
                             dt_var = dt_nplus3_rok))
)

t_nplus3_export <- list(
  tar_file(macro_export_reg_nplus3_csv,
           export_table(macro_sum_nplus3_reg,
                        here::here(c_macro_export_dir, c_macro_export_nplus3_reg_csv),
                        write_excel_csv2)),
  tar_file(macro_export_reg_nplus3_excel,
           export_table(macro_sum_nplus3_reg,
                        here::here(c_macro_export_dir, c_macro_export_nplus3_reg_xlsx),
                        write_xlsx)),
  tar_file(macro_export_nplus3_csv,
           export_table(macro_sum_nplus3,
                        here::here(c_macro_export_dir, c_macro_export_nplus3_csv),
                        write_excel_csv2)),
  tar_file(macro_export_nplus3_excel,
           export_table(macro_sum_nplus3,
                        here::here(c_macro_export_dir, c_macro_export_nplus3_xlsx),
                        write_xlsx))
)

t_nplus3_codebook <- list(
  tar_target(macro_sum_nplus3_codebook,
             make_macro_sum_codebook(macro_sum_nplus3_reg)),
  tar_file(macro_sum_nplus3_codebook_yaml,
           {pointblank::yaml_write(informant = macro_sum_nplus3_codebook %>%
                                     pointblank::set_read_fn(read_fn = ~macro_sum_nplus3_reg),
                                   path = c_macro_export_dir,
                                   filename = c_macro_export_nplus3_cdbk)
             file.path(c_macro_export_dir, c_macro_export_nplus3_cdbk)
           })
)

## Compile for macro -------------------------------------------------------

t_macro_compile <- list(
  # přidat platby po kvartálech x makro kategorie
  tar_target(efs_macrocat_fin,
             add_financials(efs_macrocat, efs_zop_quarterly)),
  tar_target(efs_macrocat_fin_reg,
             add_regions(efs_macrocat_fin, eo_kraj)),
  tar_target(prv_macrocat_fin_reg, add_regions_prv(prv_macrocat_fin)),
  # spojit PRV a ostatní, sečíst po letech a regionech
  tar_target(macro_sum_reg_annual,
             summarise_macro(efs_macrocat_fin_reg,
                             prv_macrocat_fin_reg,
                             quarterly = FALSE, regional = TRUE)),
  # spojit PRV a ostatní a sečíst po kvartálech a regionech
  tar_target(macro_sum_reg_quarterly,
             summarise_macro(efs_macrocat_fin_reg,
                             prv_macrocat_fin_reg,
                             quarterly = TRUE, regional = TRUE)),
  # spojit PRV a ostatní, sečíst po letech, bez regionu
  tar_target(macro_sum_annual,
             summarise_macro(efs_macrocat_fin,
                             prv_macrocat_fin,
                             quarterly = FALSE, regional = FALSE)),
  # spojit PRV a ostatní, sečíst po kvartálech, bez regionu
  tar_target(macro_sum_quarterly,
             summarise_macro(efs_macrocat_fin,
                             prv_macrocat_fin,
                             quarterly = TRUE, regional = FALSE))
)


## Compile by OP -----------------------------------------------------------

t_op_compile <- list(
  tar_target(compiled_op_sum,
             summarise_by_op(efs_zop_quarterly, efs_prv_quarterly)))


## Export data for macro models --------------------------------------------

t_macro_export <- list(
  tar_file(macro_export_reg_annual_csv,
           export_table(macro_sum_reg_annual,
                        here::here(c_macro_export_dir, c_macro_export_reg_csv_a),
                        write_excel_csv2)),
  tar_file(macro_export_reg_quarterly_csv,
           export_table(macro_sum_reg_quarterly,
                        here::here(c_macro_export_dir, c_macro_export_reg_csv_q),
                        write_excel_csv2)),
  tar_file(macro_export_reg_annual_excel,
           export_table(macro_sum_reg_annual,
                        here::here(c_macro_export_dir, c_macro_export_reg_xlsx_a),
                        write_xlsx)),
  tar_file(macro_export_reg_quarterly_excel,
           export_table(macro_sum_reg_quarterly,
                        here::here(c_macro_export_dir, c_macro_export_reg_xlsx_q),
                        write_xlsx)),

  tar_file(macro_export_annual_csv,
           export_table(macro_sum_annual,
                        here::here(c_macro_export_dir, c_macro_export_csv_a),
                        write_excel_csv2)),
  tar_file(macro_export_quarterly_csv,
           export_table(macro_sum_quarterly,
                        here::here(c_macro_export_dir, c_macro_export_csv_q),
                        write_excel_csv2)),
  tar_file(macro_export_annual_excel,
           export_table(macro_sum_annual,
                        here::here(c_macro_export_dir, c_macro_export_xlsx_a),
                        write_xlsx)),
  tar_file(macro_export_quarterly_excel,
           export_table(macro_sum_quarterly,
                        here::here(c_macro_export_dir, c_macro_export_xlsx_q),
                        write_xlsx))
)


## Validation and exploration ----------------------------------------------

t_valid_zop_timing <- list(
  tar_target(zop_timing_df, build_efs_timing(efs_prj, efs_zop, ef_pub)),
  tar_target(zop_timing_plot, make_zop_timing_plot(zop_timing_df))
)

t_validation <- list(
  tar_target(val_compare_sums,
             compare_dt_sums(list(efs_fin, efs_zop, efs_zop_quarterly, efs_zop_annual,
                                  efs_prv, efs_prv_quarterly,
                                  macro_sum_annual, macro_sum_reg_annual,
                                  macro_sum_quarterly, macro_sum_reg_quarterly),
                             "vyuct_czv",
                             names = c("efs_fin", "efs_zop", "efs_zop_quarterly", "efs_zop_annual",
                                       "efs_prv", "efs_prv_quarterly",
                                       "macro_sum_annual", "macro_sum_reg_annual",
                                       "macro_sum_quarterly", "macro_sum_reg_quarterly")))
)

t_preview_nplus3 <- list(
  tar_target(plt_with_nplus3,
             plot_with_nplus3(macro_sum_quarterly, macro_sum_nplus3)),
  tar_target(plt_nplus3_reg_nonreg,
             plot_nplus3_reg_nonreg(macro_sum_nplus3_reg, macro_sum_nplus3))
)


## Build and export codebook -----------------------------------------------

t_macro_codebook <- list(
  tar_target(macro_sum_codebook,
             make_macro_sum_codebook(macro_sum_reg_quarterly)),
  tar_file(macro_sum_codebook_yaml,
           {pointblank::yaml_write(informant = macro_sum_codebook %>%
                                     pointblank::set_read_fn(read_fn = ~macro_sum_reg_quarterly),
                                   path = c_macro_export_dir,
                                   filename = c_macro_export_cdbk)
             file.path(c_macro_export_dir, c_macro_export_cdbk)
           }),
  tar_target(val_compare_sums_nplus3,
             compare_dt_sums(list(efs_nplus3_remainder, efs_nplus3_fin,
                                  macro_sum_nplus3_reg,
                                  macro_sum_nplus3),
                             "zbyva_czv",
                             names = c("efs_nplus3_remainder", "efs_nplus3_fin",
                                       "macro_sum_nplus3_reg", "macro_sum_nplus3")))
)



# ESIF data 2007-13 -------------------------------------------------------

## Load and process data --------------------------------------------------

t_713_build <- list(
  tar_target(s7_katekon, load_7_katekon(c_sest_7_input_dir_new,
                                        c_sest_7_katekon)),
  tar_target(s7_platby, load_7_platby(c_sest_7_input_dir_orig,
                                      c_sest_7_platby)),
  tar_target(s7_kat, load_7_kat(c_sest_7_input_dir_orig,
                                c_sest_7_kat)),
  tar_target(s7_nuts3, load_7_nuts3(c_sest_7_input_dir_orig,
                                    c_sest_7_nuts3)),
  tar_target(cis7_op, read_excel(file.path(c_sest_7_input_dir_orig,
                                             c_cis_7_op))),
  tar_target(cis7_nuts3, read_csv(file.path(c_sest_7_input_dir_orig,
                                            c_cis_7_nuts3))),
  tar_target(s7_compiled_prj, compile_7_prj(s7_platby, s7_kat, s7_nuts3,
                                            s7_katekon, cis7_op, cis7_nuts3)),
  tar_target(s7_sum_prg, summarise_7_prg(s7_compiled_prj)),
  tar_target(s7_sum, summarise_7(s7_sum_prg))
)


## Load categorisations ----------------------------------------------------

t_713_macrocat <- list(
  tar_file(mc_7_xlsx, c_macrocat_7),
  tar_target(mc_7_quest, read_xlsx(mc_7_xlsx, "prioritni_temata") %>%
               mutate(quest_class = if_else(is.na(quest_class),
                                            quest_orig, quest_class))),
  tar_target(mc_7_hermin, read_xlsx(mc_7_xlsx, "ekonomicke_kategorie"))
)

## Integrate  categorisations ----------------------------------------------

t_713_categorise <- list(
  tar_target(s7_categorised_prj,
             categorise_7(s7_compiled_prj, mc_7_quest, mc_7_hermin)),
  tar_target(s7_sum_macro_detail,
             summarise_7_macro(s7_categorised_prj, tema_id, tema_name,
                               katekon_id, katekon_name, op_id, op_zkr)),
  tar_target(s7_sum_macro, summarise_7_macro(s7_sum_macro_detail))
)

## Export ------------------------------------------------------------------

t_713_export <- list(
  tar_file(s7_prj_pq,
           export_table(s7_compiled_prj,
                        here::here(c_export_0713_dir, c_export_0713_prj_pq),
                        write_parquet)),
  tar_file(s7_macro_detail_pq,
           export_table(s7_sum_macro_detail,
                        here::here(c_export_0713_dir, c_export_0713_detail_pq),
                        write_parquet)),
  tar_file(s7_macro_detail_csv,
           export_table(s7_sum_macro_detail,
                        here::here(c_export_0713_dir, c_export_0713_detail_csv),
                        write_excel_csv2)),
  tar_file(s7_macro_detail_xlsx,
           export_table(s7_sum_macro_detail,
                        here::here(c_export_0713_dir, c_export_0713_detail_xlsx),
                        write_xlsx)),
  tar_file(s7_macro_pq,
           export_table(s7_sum_macro,
                        here::here(c_export_0713_dir, c_export_0713_pq),
                        write_parquet)),
  tar_file(s7_macro_xlsx,
           export_table(s7_sum_macro,
                        here::here(c_export_0713_dir, c_export_0713_xlsx),
                        write_xlsx)),
  tar_file(s7_macro_csv,
           export_table(s7_sum_macro,
                        here::here(c_export_0713_dir, c_export_0713_csv),
                        write_excel_csv2)),
  tar_file(s7_kategorie_xlsx, export_0713_kategorie(s7_sum,
                                                    c_export_0713_dir,
                                                    c_export_0713_kategorie))
)


## Build and export codebook -----------------------------------------------

t_0713_codebook <- list(
  tar_target(s7_codebook,
             make_0713_codebook(s7_sum_macro_detail)),
  tar_file(s7_codebook_yaml,
           {pointblank::yaml_write(informant = s7_codebook %>%
                                     pointblank::set_read_fn(read_fn = ~s7_sum_macro_detail),
                                   path = c_export_0713_dir,
                                   filename = c_export_0713_cdbk)
             file.path(c_export_0713_dir, c_export_0713_cdbk)
           })
)


## Validate ----------------------------------------------------------------

t_validate_713 <- list(
  tar_target(plt_7_annual, plot_7_annual(s7_sum))
)

# Objective/category hierarchy --------------------------------------------

# vychází z tabulky vazeb cílů ESIF/OP/NPR/EU2020

## Matice ------------------------------------------------------------------

t_hier_matice <- list(
  tar_file(ef_hier_path, c_hier_excel_path),
  tar_target(ef_hier_raw, load_hierarchy(c_hier_excel_path, c_hier_excel_sheet)),
  tar_target(ef_hier, process_hierarchy(ef_hier_raw, efs_prj))
)

## Součet výdajů podle SC --------------------------------------------------

t_hier_soucty <- list(
  tar_target(ef_hier_sum, summarise_by_hierarchy(efs_zop_annual, efs_prj_sc, ef_hier)),
  tar_file(hier_export_xlsx,
           export_table(ef_hier_sum,
                        here::here(c_hier_export_dir, c_hier_export_xlsx),
                        write_xlsx))
)

# HTML output -------------------------------------------------------------

source("R/html_output.R")


# Compile targets lists ---------------------------------------------------

list(t_public_list, t_cats,
     t_html, t_esif_obce, t_sestavy, t_hier_matice, t_hier_soucty,
     t_op_compile, t_valid_zop_timing, t_validation,
     t_713_build, t_713_export, t_0713_codebook, t_713_macrocat,
     t_713_categorise, t_validate_713,
     t_nplus3, t_nplus3_sum, t_nplus3_export, t_nplus3_codebook,
     t_preview_nplus3,
     t_macro_compile, t_macro_export, t_macro_codebook)
