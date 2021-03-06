#####################################
##### UPLOAD AND CLEAN THE DATA #####
#####################################

### Upload data:


### Script to clean the data:

# extract country codes:
country_codes <- wb_cachelist$countries %>%
  select(iso3c, country) %>%
  mutate(country_name = country,
         country = iso3c)

country_pop <- filter(world_bank_pop, indicator=="SP.POP.TOTL" | indicator=="SP.URB.TOTL") %>%
  select(country,indicator,`2017`) %>%
  pivot_wider(names_from = indicator, values_from = `2017`) %>%
  mutate(percent_urban = SP.URB.TOTL/SP.POP.TOTL) %>%
  left_join(country_codes) %>%
  mutate(population = SP.POP.TOTL) %>%
  select(country=country_name, population, percent_urban)

gal_visit_month <- read_csv("data/galapagos_monthly_visitation_2015_2017.csv")
gal_visit_country <- read_csv("data/galapagos_visitation_2017.csv")


latest_CV_data <- read_csv("data/Feb 26 Coronavirus data.csv")

total_cases <- apply(select(latest_CV_data, -country),2,FUN=function(x) sum(x,na.rm=T))
  
### Connect CV data to galapagos country visits data:
combined_data <- left_join(gal_visit_country, latest_CV_data)

galap_num_data <- select(combined_data, names(total_cases))
total_cases_gal <- apply(galap_num_data,2,FUN=function(x) sum(x,na.rm=T))

other_countries <- total_cases - total_cases_gal

for(i in names(other_countries)){
  combined_data[3,i] <- other_countries[i]
}

combined_data_clean <- mutate(combined_data,
                              total_cases = replace_na(total_cases, 0),
                              new_cases = replace_na(new_cases, 0),
                              deaths = replace_na(deaths, 0),
                              new_deaths = replace_na(new_deaths, 0),
                              total_rec = replace_na(total_rec, 0),
                              total_critical = replace_na(total_critical, 0))

### now add the population data:
data_semifin <- left_join(combined_data_clean, country_pop) %>%
  mutate(urban_pop = percent_urban*population)

urban_pop_tot <- sum(data_semifin$urban_pop, na.rm=T)
# total urban population of the world is 4.2 billion, so the 2509 other corona cases come from the total remaining urban pop
# (in other words, excluding those already on the list):
total_remaining_urb_pop <- 4200000000 - urban_pop_tot

# do the same for regular pop:
normal_pop_tot <- sum(data_semifin$population, na.rm=T)
total_remaining_norm_pop <- 7530000000 - normal_pop_tot

# now put those in the data:
data_semifin[3,"population"] <- total_remaining_norm_pop
data_semifin[3,"urban_pop"] <- total_remaining_urb_pop
data_semifin[3,"percent_urban"] <- total_remaining_urb_pop/total_remaining_norm_pop



### Now clean up the coronavirus time series:
data(coronavirus)
CV_time_old_data <- select(coronavirus, date, cases, type) %>%
  filter(type=="confirmed") %>% # filter out only confirmed cases (not deaths or recoveries since those are redundant)
  arrange(date) %>%
  group_by(date) %>%
  summarize(cases = sum(cases)) %>%
  ungroup() %>%
  mutate(cases_cum = cumsum(cases),
         cases_cum = cases_cum+555) # total number of cases was 555 on January 22, so add this number to the cumsum to get the real growing number:
                                    # https://edition.cnn.com/asia/live-news/wuhan-coronavirus-china-intl-hnk/h_ae5f21c45877ccc6847e9e04068754ca

# ### Add the latest numbers: from https://www.worldometers.info/coronavirus/
# date <- seq.Date(as.Date("2020-02-17"), as.Date("2020-02-28"), by="day")
# cases_cum <- c(73332,75184,75700,76677,77673,78651,79205,80087,80828,81830,83113,84624)
# cases <- NA
# CV_time_data <- rbind(CV_time_old_data, tibble(date,cases,cases_cum))
# # confirm that the diff function works to fill in missing case numbers (all should be zero):
# #c(555,diff(CV_time_data$cases_cum)) - CV_time_data$cases
# CV_time_data$cases <- c(555,diff(CV_time_data$cases_cum))
# CV_time_data <- CV_time_old_data


### Now model the growthrate of the virus:
### Function to fit an logistic or exponential curve to the virus growth and spread:
days <- as.numeric(CV_time_data$date-min(CV_time_data$date))+1
growth_model <- function(max_infected=10000000, type="exp", days2pred=days.pred, CVdata=CV_time_data, return_active=F){
  #date_values <- seq.Date(as.Date("2020-01-22"), as.Date("2020-03-31"), by="day")
  days <- as.numeric(CVdata$date-min(CVdata$date))+1
  ### First estimate starting parameters from linear model:
  # # Select an approximate theta, since theta must be lower than min(y), and greater than zero
  theta.0 <- min(CVdata$cases_cum) * 0.5  
  model.0 <- lm(log(cases_cum-theta.0) ~ days, data=CVdata)  
  alpha.0 <- exp(coef(model.0)[1])
  beta.0 <- coef(model.0)[2]
  start <- list(alpha = alpha.0, beta = beta.0)
  K.0 <- 2000000
  start.K <- list(alpha = alpha.0, beta = beta.0, K.par = K.0)
  #start.thet <- list(alpha = alpha.0, beta = beta.0, theta=theta.0)
  
  #number of days to predict:
  days.pred <- days2pred
  
  if(type=="log"){
    if(max_infected=="auto"){
      nls.model.logist.K <- nls(cases_cum~ K.par/(1+alpha*exp(beta*days))-11000, data=CVdata, start=start.K)
      corona_pred <- predict(nls.model.logist.K, list(days=days.pred))
    } else {
      nls.model.logist <- nls(cases_cum~ max_infected/(1+alpha*exp(beta*days))-11000, data=CVdata, start=start)
      corona_pred <- predict(nls.model.logist, list(days=days.pred))
    }
  }
  
  if(type=="exp"){
    nls.model <- nls(cases_cum~ alpha * exp(beta*days)-11000, data=CVdata, start=start)
    corona_pred <- predict(nls.model, list(days=days.pred))
    # nls.model.theta <- nls(cases_cum~ alpha * exp(beta*days)-theta, data=CV_time_data, start=start.thet)
    # corona_pred <- predict(nls.model.theta, list(days=days.pred))
  }
  
  if(type=="lin"){
    lm.model <- lm(cases_cum~ days, data=CVdata)
    corona_pred <- predict(lm.model, list(days=days.pred))
  }
  
  ### Now calculate the total number of active cases (rolling total every 30 days) for each prdiction:
  ### Add in the fact that one month after diagnosis (look up this number), the person is no longer infected, so the total
  ### pool of cases to choose from at any moment is only the number of "active" cases and not cumulative total. To find this
  ### Calculate how many new cases there are each day, and from that calculate a moving window cumulative sum within 30 days.
  
  number_new_cases <- corona_pred - lag(corona_pred)
  number_new_cases[1] <- corona_pred[1]
  number_new_cases <- ceiling(number_new_cases)
  
  active_cases <- NULL
  for(i in 1:length(number_new_cases)){
    # active cases are the sum of the range of cases from 
    active_cases[i] <- sum(number_new_cases[max(c(i-30,1)):i])
  }
  if(return_active) return(active_cases) else return(corona_pred)
}

### Calculate proportion of infected that each country has:
data_fin <- select(data_semifin, country, gal_visitors = proj_2020, total_CV_cases=total_cases, cntry_urban_pop=urban_pop) %>%
  mutate(total_CV_cases = total_CV_cases+1, # adding 1 to all countries to make sure they all have the chance of becoming infected and dont stay zero
         total_CV_cases_prop = total_CV_cases/sum(total_CV_cases))

### Now, project the number of cases in each country by this percentage into the future
projected_CV_by_country <- function(total_infected) {
  country_proj <- ceiling(data_fin$total_CV_cases_prop * total_infected)
  names(country_proj) <- data_fin$country
  return(country_proj)
}
projected_CV_by_country(1000)

### Calculate the proportion of vistors each month from each country based on the average proportion in the last three years
gal_monthly_sum <- group_by(gal_visit_month, month) %>%
  summarize(mean_num = mean(number)) %>%
  ungroup() %>%
  mutate(monthly_prop = mean_num/sum(mean_num),
         daily_prop = monthly_prop/c(31,28,31,30,31,30,31,31,30,31,30,31),
         month=as.factor(month))
#plot(daily_prop ~ as.factor(month), data=gal_monthly_sum)

### Then turn that calculation into a daily number of people from each country arriving
# function to extract daily number of visitors from each country:
daily_visitors <- function(month="february"){
  daily_prop <- gal_monthly_sum$daily_prop[gal_monthly_sum$month==month]
  daily_vis <- ceiling(daily_prop*data_fin$gal_visitors)
  names(daily_vis) <- data_fin$country
  return(daily_vis)
}
gal_monthly_sum




