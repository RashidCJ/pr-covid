# -- Libraries
library(tidyverse)
library(lubridate)
library(splines)

# -- Fixed values
first_day <- make_date(2020, 3, 12)
url <- "https://bioportal.salud.gov.pr/api/administration/reports/minimal-info-unique-tests"


# Reading data from database ----------------------------------------------
all_tests <- jsonlite::fromJSON(url)

# Wrangling test data -----------------------------------------------------

## defining age levels
age_levels <-  c("0 to 9", "10 to 19", "20 to 29", "30 to 39", "40 to 49", "50 to 59", "60 to 69", 
                 "70 to 79", "80 to 89", "90 to 99", "100 to 109", "110 to 119", "120 to 129")

## Defining rda with all the tests 
all_tests <- all_tests %>%  
  as_tibble() %>%
  mutate(collectedDate  = mdy(collectedDate),
         reportedDate   = mdy(reportedDate),
         createdAt      = mdy_hm(createdAt),
         ageRange       = na_if(ageRange, "N/A"),
         ageRange       = factor(ageRange, levels = age_levels),
         patientCity    = ifelse(patientCity == "Loiza", "Loíza", patientCity),
         patientCity    = ifelse(patientCity == "Rio Grande", "Río Grande", patientCity),
         patientCity    = factor(patientCity),
         result         = tolower(result),
         result         = case_when(grepl("positive", result) ~ "positive",
                                    grepl("negative", result) ~ "negative",
                                    result == "not detected" ~ "negative",
                                    TRUE ~ "other")) %>%
         arrange(reportedDate, collectedDate) 

## fixing dates: if you want to remove bad dates instead, change FALSE TO TRUE
if(FALSE){
  ## remove bad dates
  all_tests <- all_tests %>% 
  filter(!is.na(collectedDate) & year(collectedDate) == 2020 & collectedDate <= today()) %>%
  mutate(date = collectedDate) 
} else{
  ## Impute missing dates
  all_tests <- all_tests %>% mutate(date = if_else(is.na(collectedDate), reportedDate - days(2),  collectedDate))
  ## Remove inconsistent dates
  all_tests <- all_tests %>%
    mutate(date = if_else(year(date) != 2020 | date > today(), reportedDate - days(2),  date)) %>%
    filter(year(date) == 2020 & date <= today()) %>%
    arrange(date, reportedDate)
}


# -- Computing observed tasa de positividad and smooth fit

tests <- all_tests %>%  
  filter(date>=first_day) %>%
  filter(result %in% c("positive", "negative")) %>%
  group_by(date) %>%
  dplyr::summarize(positives = sum(result == "positive"), tests = n()) %>%
  ungroup() %>%
  mutate(rate = positives / tests) %>%
  mutate(weekday = factor(wday(date)))

##Extracting variables for model fit
x <- as.numeric(tests$date)
y <- tests$positives
n <- tests$tests

## Design matrix for splines
## We are using 3 knots per monnth
df  <- round(3 * (nrow(tests))/30)
nknots <- df - 1
# remove boundaries and also 
# remove the last knot to avoid unstability due to lack of tests during last week
knots <- seq.int(from = 0, to = 1, length.out = nknots + 2L)[-c(1L, nknots + 1L, nknots + 2L)]
knots <- quantile(x, knots)
x_s <- ns(x, knots = knots, intercept = FALSE)

i_s <- c(1:(ncol(x_s)+1))

## Design matrix for weekday effect
w            <- factor(wday(tests$date))
contrasts(w) <- contr.sum(length(levels(w)), contrasts = TRUE)
x_w          <- model.matrix(~w)

## Design matrix
X <- cbind(x_s, x_w)

## Fitting model 
fit  <- glm(cbind(y, n-y) ~ -1 + X, family = "quasibinomial")
beta <- coef(fit)

## Computing probabilities
tests$fit <- as.vector(X[, i_s] %*% beta[i_s])
tests$se  <- sqrt(diag(X[, i_s] %*%
                         summary(fit)$cov.scaled[i_s, i_s] %*%
                         t(X[, i_s])) * pmax(1,summary(fit)$dispersion))
if(FALSE){
  alpha <- 0.01
  z <- qnorm(1-alpha/2)
  
  expit <- function(x) { 1/ (1 + exp(-x))  }
  
  tests %>%
    filter(date >= make_date(2020,3,21) & date <= today()) %>%
    ggplot(aes(date, rate)) +
    geom_hline(yintercept = 0.05, lty=2, color = "gray") +
    geom_point(aes(date, rate), size=2, alpha = 0.65) +
    geom_ribbon(aes(ymin= expit(fit - z*se), ymax = expit(fit + z*se)), alpha = 0.35) +
    geom_line(aes(y = expit(fit)), color="blue2", size = 0.80) +
    ylab("Tasa de positividad") +
    xlab("Fecha") +
    ggtitle("Tasa de Positividad en Puerto Rico") +
    scale_y_continuous(labels = scales::percent) +
    scale_x_date(date_labels = "%B %d") +
    geom_smooth(method = "loess", formula = "y~x", span = 0.2, method.args = list(degree = 1, weight = tests$tests), color = "red", lty =2, fill = "pink") +
    theme_bw()
}

# -- summaries stratified by age group and patientID
tests_by_strata <- all_tests %>%  
  filter(date>=first_day) %>%
  filter(result %in% c("positive", "negative")) %>%
  mutate(patientCity = fct_explicit_na(patientCity, "No reportado")) %>%
  mutate(ageRange = fct_explicit_na(ageRange, "No reportado")) %>%
  group_by(date, patientCity, ageRange, .drop = FALSE) %>%
  dplyr::summarize(positives = sum(result == "positive"), tests = n()) %>%
  ungroup()


# --Mortality and hospitlization
hosp_mort <- read_csv("https://raw.githubusercontent.com/rafalab/pr-covid/master/dashboard/data/DatosMortalidad.csv") %>%
  mutate(date = mdy(Fecha)) %>% 
  filter(date >= first_day) 


# -- Extracting variables for model fit
x <- as.numeric(hosp_mort$date)
y <- hosp_mort$IncMueSalud

# -- Design matrix for splines
df  <- round(nrow(hosp_mort)/30)
x_s <- ns(x, df = df, intercept = FALSE)
i_s <- c(1:(ncol(x_s)+1))

# -- Design matrix for weekday effect
w            <- factor(wday(hosp_mort$date))
contrasts(w) <- contr.sum(length(levels(w)), contrasts = TRUE)
x_w          <- model.matrix(~w)

# -- Design matrix
X <- cbind(x_s, x_w)

# -- Fitting model 
fit  <- glm(y ~ -1 + X, family = "quasipoisson")
beta <- coef(fit)

# -- Computing probabilities
hosp_mort$fit <- as.vector(X[, i_s] %*% beta[i_s])
hosp_mort$se  <- sqrt(diag(X[, i_s] %*%
                             summary(fit)$cov.scaled[i_s, i_s] %*%
                             t(X[, i_s]))* pmax(1,summary(fit)$dispersion))

# -- Save data

## if on server, save with full path
## if not on server, save to home directory
if(Sys.info()["nodename"] == "fermat.dfci.harvard.edu"){
  rda_path <- "/homes10/rafa/dashboard/rdas"
} else{
  rda_path <- "rdas"
}

## define date and time of latest download
the_stamp <- now()
save(tests, tests_by_strata, hosp_mort, the_stamp, file = file.path(rda_path,"data.rda"))
## save the big file for those that want to download it
saveRDS(all_tests, file = file.path(rda_path, "all_tests.rds"), compress = "xz")

