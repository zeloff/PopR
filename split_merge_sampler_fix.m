function [class_ids, K_record, k_0s, alpha_record,K_mix_record] = split_merge_sampler_fix(...
    training_data,priors,baseline,baseline_sources,num_sweeps,intro,GRAPHICS,thin)

addpath C:\Users\Philipp\Work\Otolith_Code\Bayesian_NP\lightspeed\lightspeed

% This code samples from the posterior of the Dirichlet Process Mixture
% model with conjugate Normal-Inv-Wishart prior, using the Split-Merge
% sampler proposed by Jain & Neal 2004 with improvements by Dahl 2005.
% Credit goes to Frank Wood (Columbia U.), on who's Gibbs sampler the Gibbs
% portion of the present code is based. The Split-Merge algo is my doing; no
% guarantee is given that code is correct or will produce correct results.
% Note, the code is quite efficient with sequential updating of sufficient
% stats at both levels (except for some places were I couldn't be asked to
% figure it out) - specifying GRAPHICS will take a LOT mote time, I therefore
% recommend to use real-time plots only initially to get things right,
% and then to update without plots. Use at your own discretion.

% Inputs are the data (training_data), the number of iterations (sweeps),
% the hyperparameters for the alpha parameter gamma prior (a_0,b_0), a
% prior guess at the mean vector (mu_0), k_0 measures the confidence in
% mu_0 (k_0 = 1 encodes little prior info); the initial degrees of freedom
% of the inv_Wishart prior - the higher, the more confident we are in our
% prior guess for the covarinace matrix Sigma (lambda_0)(needs to be number
% of dimensions of the data +1). To express a
% prior belief in Sigma, note that the expectation E of Sigma in this
% parametrization is (1/(v_0-p-1)*lambda_0^-1)^-1 , thus, to encode the prior set
% lambda_0 to (1/(v_0-p-1)*prior_E^-1)^-1. max_class_id is set to keep manageable
% data-structures. Set to a size well well above realized samples - or at
% length(data).

% the code returns class_ids (a matrix of N*sweeps assignmets to classes at
% each iteration; be aware that label switching makes the numerical values of these variables
% arbitrary); K_record (a 1*sweeps vector of number of classes at each
% iteration); lp_record (a vector of log-probabilities proportional to the P
% of the model given the data); and alpha_record (the recorded alpha values
% at each iteration)

% Copyright Phil Neubauer@ Victoria University of Wellington, NZ, permission
% is granted to use, reproduce and modify the code at will. Please cite the
% corresponding paper(s) when using this code in any way.

uniqs=unique(baseline_sources);
for i=1:length(unique(baseline_sources))
    baseline_sources(baseline_sources==uniqs(i))=i;
end

% set alpha gamma prior parameters (vague, following Navarro)

a_0 = priors.a_0;
b_0 = priors.b_0;

% set normal inverse wishart hyper parameters

mu_0 = priors.mu_0;
k_0 = priors.k_0;


v_0=priors.v_0;
lambda_0 = priors.var;
alpha = 0.001;

%% real start

[D, N] = size(training_data);
max_class_id = N;
% specify a memory efficient type for class_ids
class_id_type = 'uint16';
d=D;
sources=size(unique(baseline_sources),2)
K_plus = sources;
class_ids = zeros(N,round(num_sweeps/thin),class_id_type);
class_id = zeros(N,2,class_id_type);
K_record = zeros(round(num_sweeps/thin),1);
K_mix_record = zeros(round(num_sweeps/thin),1);
alpha_record = zeros(round(num_sweeps/thin),1);
k_0s= zeros(round(num_sweeps/thin),1);

% precompute student-T posterior predictive distribution constants
pc_max_ind = 1e5;
pc_gammaln_by_2 = 1:pc_max_ind;
pc_gammaln_by_2 = gammaln(pc_gammaln_by_2/2);
pc_log_pi = reallog(pi);
pc_log = reallog(1:pc_max_ind);

means = zeros(D,max_class_id);
orgmeans  = zeros(D,max_class_id);
orgsum_squares = zeros(D,D,max_class_id);
mu_0s = zeros(D,num_sweeps);
%k_0s=zeros(num_sweeps,1);
sum_squares = zeros(D,D,max_class_id);
inv_cov = zeros(D,D,max_class_id);
log_det_cov = zeros(max_class_id,1);
counts = zeros(max_class_id,1,'uint32');
allcounts = zeros(max_class_id,1,'uint32');
ns = zeros(max_class_id,1);
is=unique(baseline_sources);

orginv_cov=[];orglog_det_cov=[];
for i=1:length(unique(baseline_sources))
    
    means(:,i) = mean(baseline(:,baseline_sources==is(i)),2);
    orgmeans(:,i) = mean(baseline(:,baseline_sources==is(i)),2);
    allcounts (i) = size(baseline(:,baseline_sources==is(i)),2);
    ns(i) = size(baseline(:,baseline_sources==is(i)),2);
    orgsum_squares(:,:,i) = (baseline(:,baseline_sources==is(i))-repmat(mean(baseline(:,baseline_sources==is(i)),2),1,double(allcounts(i))))*(baseline(:,baseline_sources==is(i))-repmat(mean(baseline(:,baseline_sources==is(i)),2),1,double(allcounts(i))))';
    sum_squares(:,:,i) = (baseline(:,baseline_sources==is(i))-repmat(mean(baseline(:,baseline_sources==is(i)),2),1,double(allcounts (i))))*(baseline(:,baseline_sources==is(i))-repmat(mean(baseline(:,baseline_sources==is(i)),2),1,double(allcounts(i))))';
    
    orgsum_squares(:,:,i) = orgsum_squares(:,:,i)+ns(i)*(means(:,i)*means(:,i)');
    sum_squares(:,:,i) = sum_squares(:,:,i)+ns(i)*(means(:,i)*means(:,i)');
    
    n = size(baseline(:,baseline_sources==is(i)),2);
    k_n = k_0+n;
    v_n = v_0+n;
    
    zm_Y = means(:,i)-mu_0;
    SS = sum_squares(:,:,i)-n*(means(:,i)*means(:,i)');
    lambda_n = lambda_0 + SS + ...
        k_0*n/(k_0+n)*(zm_Y)*(zm_Y)';
    Sigma = lambda_n*(k_n+1)/(k_n*(v_n-d+1));
    
    log_det_cov(i) = log(det(Sigma));
    orglog_det_cov(i) = log(det(Sigma));
    inv_cov(:,:,i) = inv(Sigma);
    orginv_cov(:,:,i) = inv(Sigma);
end
yyT = zeros(D,D,N);
%for each ind allocate it to the closest mean and update the SSs
for i=1:N
    
    y = training_data(:,i);
    
    for j=1:length(unique(baseline_sources))
        dists(j) =  sqrt(sum((y-orgmeans(:,j)).^2));
    end
    
    choose=find(rand>=(1-cumsum(dists./sum(dists))),1);
    allcounts(choose)=allcounts(choose)+1;
    counts(choose)=counts(choose)+1;
    class_id(i,1)=choose;
    
    n = double(allcounts(choose));
    yyT(:,:,i) = y*y';
    
    means(:,choose) = means(:,choose) + (1/n)*(y-means(:,choose));
    sum_squares(:,:,choose) = sum_squares(:,:,choose) + yyT(:,:,i);
    
    
    k_n = k_0+n;
    v_n = v_0+n;
    
    zm_Y = means(:,choose)-mu_0;
    SS = sum_squares(:,:,choose)-n*(means(:,choose)*means(:,choose)');
    lambda_n = lambda_0 + SS + ...
        k_0*n/(k_0+n)*(zm_Y)*(zm_Y)';
    Sigma = lambda_n*(k_n+1)/(k_n*(v_n-d+1));
    
    log_det_cov(choose) = log(det(Sigma));
    
    inv_cov(:,:,choose) = inv(Sigma);
    
end

K_plus = max(class_id(:,1));
d2 = D/2;

% initialize timers
time_1_obs = 0;
total_time = 0;

%% SASM sampler

% run the sampler
for sweep = 1:num_sweeps
    
    %% p under prior and y alone
    %sweep=sweep+1
    % pre-compute the probability of each point under the prior alone
    p_under_prior_alone = zeros(N,1);
    
    Sigma = (lambda_0*(k_0+1)/(k_0*(v_0-D+1)))';
    v = v_0-D+1;
    mu = mu_0;
    log_det_Sigma = log(det(Sigma));
    inv_Sigma = Sigma^-1;
    vd = v+D;
    
    for i=1:N
        y = training_data(:,i);
        
        lp = pc_gammaln_by_2(vd) - (pc_gammaln_by_2(v) + d2*pc_log(v) + ...
            d2*pc_log_pi) - .5*log_det_Sigma-...
            (vd/2)*log(1+(1/v)*(y-mu)'*inv_Sigma*(y-mu));
        
        p_under_prior_alone(i) = lp;
        
    end
    
    %% display progress
    
    
    total_time = total_time + time_1_obs;
    if sweep==1
        disp(['Sweep: ' num2str(sweep) '/' num2str(num_sweeps) ]);
    elseif mod(sweep,max(thin,50))==0
        E_K_plus = mean(K_mix_record(1:round(sweep/thin)));
        rem_time = (time_1_obs*.05 + 0.95*(total_time/sweep))*num_sweeps-total_time;
        if rem_time < 0
            rem_time = 0;
        end
        disp(['Sweep: ' num2str(sweep) '/' num2str(num_sweeps) ', Rem. Time: '...
            secs2hmsstr(rem_time) ', E[K^+] ' num2str(E_K_plus)]);
    end
    tic
    
    %% split merge section
    
    if sweep>intro
        class_id(:,2) = class_id(:,1);
        
        class_id_temp = class_id(:,2);
        % choose individuals at random
        ind = randsample(N,2);
        c_i = class_id(ind(1),2);
        c_j = class_id(ind(2),2);
        
        n_i = sum(class_id(:,2)==c_i);
        n_j = sum(class_id(:,2)==c_j);
        
        likelihood = zeros(2,1);
        
        if c_i~=c_j
            %% merge
            
            if (c_i>sources && c_j>sources) || ((c_i<=sources && c_j<=sources) && n_i >= n_j) || (c_i<=sources && c_j>sources)
                
                class_id_temp(class_id(:,2)==c_j) = c_i;% rename class_id of ind(1) to that of ind(2)
                
                if c_j>sources || c_i>sources % only need to compact if one is not from baseline
                    
                    hits = class_id_temp >= c_j; % get class_ids of id_s greater than the merged one
                    class_id_temp(hits) = class_id_temp(hits)-1; % compact class_id_temp
                    
                end
                
            else
                
                class_id_temp(class_id(:,2)==c_i) = c_j;% rename class_id of ind(1) to that of ind(2)
                
                if c_j>sources || c_i>sources % only need to compact if one is not from baseline
                    
                    hits = class_id_temp >= c_i; % get class_ids of id_s greater than the merged one
                    class_id_temp(hits) = class_id_temp(hits)-1; % compact class_id_temp
                    
                end
                
            end
            % backwards reallocate, keeping track of the probas for the M-H ratio
            % for this I need the sufficient stats for the 'old' groups in
            % the merge case starting from one single obs in each group
            % (RANDOM SAMPLE THE ORDER! (Dahl 2003))
            
            if c_i>sources && c_j>sources
                
                n_S(1) = 1; % keeps track of the number of items at each 'new-old' component
                n_S(2) = 1;
                
                meens(:,1) = training_data(:,ind(1));
                meens(:,2) = training_data(:,ind(2));
                
                sum_s(:,:,1) = yyT(:,:,ind(1));
                sum_s(:,:,2) = yyT(:,:,ind(2));
                
            else
                
                n_S(1) = 1+ns(c_i); % keeps track of the number of items at each 'new-old' component
                n_S(2) = 1+ns(c_j);
                
                
                meens(:,1) = orgmeans(:,c_i) + (1/n_S(1))*(training_data(:,ind(1))-orgmeans(:,c_i));
                meens(:,2) = orgmeans(:,c_j) + (1/n_S(2))*(training_data(:,ind(2))-orgmeans(:,c_j));
                
                sum_s(:,:,1) = orgsum_squares(:,:,c_i) + yyT(:,:,ind(1));
                sum_s(:,:,2) = orgsum_squares(:,:,c_j) + yyT(:,:,ind(2));
                
            end
            
            
            ixxs=find(class_id(:,2)==c_j | class_id(:,2)==c_i);
            ixxs(ixxs==ind(1) | ixxs==ind(2))=[];
            ixxs=[ind(1); ind(2); ixxs];
            
            %which one do we merge ?
            if (c_i>sources && c_j>sources) || ((c_i<=sources && c_j<=sources) && n_i >= n_j) || (c_i<=sources && c_j>sources)
                merga = c_i;
                cnt=[1 2]; % which way around do we start ?
                cns = n_S(1)-1;
                antimerga = c_j;
                nmerge = n_j;
                cmeans = orgmeans(:,c_i);
                csums = orgsum_squares(:,:,c_i);
            else
                cns = n_S(2)-1;
                merga = c_j;
                cnt=[2 1];
                antimerga = c_i;
                nmerge = n_i;
                cmeans = orgmeans(:,c_j);
                csums = orgsum_squares(:,:,c_j);
            end
            
            
            clik=1;cprod=1;setlik=1;likelihood=zeros(1,2);
            prob_i=zeros(2,1);
            for o = [cnt (randperm(n_i+n_j-2)+2)]
                
                k=ixxs(o);
                
                % calculate the combined likelihood
                
                y_k = training_data(:,k);
                
                m_Y = cmeans;
                k_n = k_0+cns;
                mu_n = k_0/(k_n)*mu_0 + cns/(k_n)*m_Y;
                v_n = v_0+cns;
                v = v_n-D+1;
                
                S = (csums - cns*(m_Y*m_Y'));
                zm_Y = m_Y-mu_0;
                lambda_n = lambda_0 + S  + k_0*cns/(k_n)*(zm_Y)*(zm_Y)';
                Sigma = (lambda_n*(k_n+1)/(k_n*v))';
                vd = v+D;
                
                clikelihood = pc_gammaln_by_2(vd) - (pc_gammaln_by_2(v) + d2*pc_log(v) + ...
                    d2*pc_log_pi) - .5*log(det(Sigma))-...
                    (vd/2)*reallog(1+(1/v)*(y_k-mu_n)'*Sigma^-1*(y_k-mu_n));
                
                clik=clik*exp(clikelihood);
                cns=cns+1;
                cmeans = cmeans + (1/cns)*(y_k-cmeans);
                csums = csums + yyT(:,:,k);
                
                
                % calculate individual set likelihoods
                
                if o==1 || o==2
                    
                    for ell = 1:2
                        n = double(n_S(ell)-1);
                        m_Y = orgmeans(:,class_id(ind(ell),2));
                        k_n = k_0+n;
                        mu_n = k_0/(k_n)*mu_0 + n/(k_n)*m_Y;
                        v_n = v_0+n;
                        
                        v = v_n-D+1;
                        mu = mu_n;
                        
                        S = (orgsum_squares(:,:,class_id(ind(ell),2)) - n*(m_Y*m_Y'));
                        zm_Y = m_Y-mu_0;
                        lambda_n = lambda_0 + S  + ...
                            k_0*n/(k_n)*(zm_Y)*(zm_Y)';
                        Sigma = (lambda_n*(k_n+1)/(k_n*(v_n-D+1)))';
                        
                        log_det_Sigma = log(det(Sigma));
                        inv_Sigma = Sigma^-1;
                        log_det_cov(ell) = log_det_Sigma;
                        inv_cov(:,:,ell) = inv_Sigma;
                        
                        vd = v+D;
                        
                        likelihood(ell) = pc_gammaln_by_2(vd) - (pc_gammaln_by_2(v) + d2*pc_log(v) + ...
                            d2*pc_log_pi) - .5*log_det_Sigma-...
                            (vd/2)*reallog(1+(1/v)*(y_k-mu)'*inv_Sigma*(y_k-mu));
                        
                    end
                    likelihood = exp(likelihood);
                    setlik=setlik*likelihood(o);
                    
                    continue
                end
                
                
                for ell = 1:2
                    n = double(n_S(ell));
                    m_Y = meens(:,ell);
                    k_n = k_0+n;
                    mu_n = k_0/(k_n)*mu_0 + n/(k_n)*m_Y;
                    v_n = v_0+n;
                    
                    % set up variables for Gelman's formulation of the Student T
                    % distribution
                    v = v_n-D+1;
                    mu = mu_n;
                    
                    S = (sum_s(:,:,ell) - n*(m_Y*m_Y'));
                    zm_Y = m_Y-mu_0;
                    lambda_n = lambda_0 + S  + ...
                        k_0*n/(k_n)*(zm_Y)*(zm_Y)';
                    Sigma = (lambda_n*(k_n+1)/(k_n*(v_n-D+1)))';
                    
                    log_det_Sigma = log(det(Sigma));
                    inv_Sigma = Sigma^-1;
                    log_det_cov(ell) = log_det_Sigma;
                    inv_cov(:,:,ell) = inv_Sigma;
                    
                    vd = v+D;
                    
                    likelihood(ell) = pc_gammaln_by_2(vd) - (pc_gammaln_by_2(v) + d2*pc_log(v) + ...
                        d2*pc_log_pi) - .5*log_det_Sigma-...
                        (vd/2)*reallog(1+(1/v)*(y_k-mu)'*inv_Sigma*(y_k-mu));
                    
                end
                
                m_S(1)=n_S(1)-ns(c_i);
                m_S(2)=n_S(2)-ns(c_j);
                
                
                likelihood = exp(likelihood);
                prob_i(1) = (m_S(1)*likelihood(1))/sum(m_S.*likelihood); % the proba of choosing S_i for individual k
                prob_i(2) = 1-prob_i(1);
                
                if rand<prob_i(1) % S_i is chosen
                    
                    setlik=setlik*likelihood(1);
                    cprod=cprod*prob_i(1);
                    
                    n_S(1) = n_S(1)+1;
                    
                    meens(:,1) = meens(:,1)+ (1/n_S(1))*(y_k-meens(:,1));
                    sum_s(:,:,1) = sum_s(:,:,1) + yyT(:,:,k);
                    
                else % S_j is chosen
                    
                    setlik=setlik*likelihood(2);
                    cprod=cprod*prob_i(2);
                    
                    n_S(2) = n_S(2)+1;
                    
                    meens(:,2) = meens(:,2)+ (1/n_S(2))*(y_k-meens(:,2));
                    sum_s(:,:,2) = sum_s(:,:,2) + yyT(:,:,k);
                    
                end
                
            end
            
            
            M_H_prior = exp(gammaln(n_j+n_i)-(gammaln(n_S(1)-ns(c_i))+gammaln(n_S(2)-ns(c_j))))/alpha;
            M_H_Lik =clik/setlik;
            M_H_rat = M_H_prior*(M_H_Lik)*cprod;
            
            if rand<M_H_rat % accept ?
                % %                 disp('accept merge')
                % %                 sweep
                % first update suff-stats of new merged group
                
                means(:,merga) = (double(allcounts(merga))*means(:,merga) + double(allcounts(antimerga))*means(:,antimerga))./double(allcounts(antimerga)+allcounts(merga));
                sum_squares(:,:,merga) = sum_squares(:,:,c_j) + sum_squares(:,:,c_i);
                
                counts(merga) = n_i + n_j;
                allcounts(merga)=allcounts(merga)+nmerge;
                % update relevant quantities for student -t for merga
                
                m_Y = means(:,merga);
                n=double(allcounts(merga));
                k_n = k_0+n;
                v_n = v_0+n;
                
                S = (sum_squares(:,:,merga) - n*(m_Y*m_Y'));
                zm_Y = m_Y-mu_0;
                lambda_n = lambda_0 + S  + ...
                    k_0*n/(k_0+n)*(zm_Y)*(zm_Y)';
                Sigma = (lambda_n*(k_n+1)/(k_n*(v_n-D+1)))';
                
                log_det_cov(merga) = log(det(Sigma));
                inv_cov(:,:,merga) = Sigma^-1;
                
                % then delete old table
                
                class_id(:,2)=class_id_temp;
                
                if antimerga>sources
                    
                    K_plus =  K_plus-1;
                    hits = [1:antimerga-1 antimerga+1:(K_plus+1)];
                    means(:,1:K_plus) = means(:,hits);
                    means(:,K_plus+1) = 0;
                    sum_squares(:,:,1:K_plus) = sum_squares(:,:,hits);
                    sum_squares(:,:,1+K_plus) = 0;
                    counts(1:K_plus) = counts(hits);
                    counts(K_plus+1) = 0;
                    allcounts(1:K_plus) = allcounts(hits);
                    allcounts(K_plus+1) = 0;
                    % DEAL WITH LDC and LDETCOV here aswell
                    
                    log_det_cov(1:K_plus) = log_det_cov(hits);
                    log_det_cov(K_plus+1) = 0;
                    inv_cov(:,:,1:K_plus) = inv_cov(:,:,hits);
                    inv_cov(:,:,K_plus+1) = 0;
                    
                else % just replace with old table
                    
                    means(:,antimerga) = orgmeans(:,antimerga);
                    sum_squares(:,:,antimerga) = orgsum_squares(:,:,antimerga);
                    counts(antimerga) = 0;
                    allcounts(antimerga) = allcounts(antimerga)-nmerge;
                    % DEAL WITH LDC and LDETCOV here aswell
                    
                    log_det_cov(antimerga) = orglog_det_cov(antimerga);
                    inv_cov(:,:,antimerga) = orginv_cov(:,:,antimerga);
                    
                    K_plus = sum(allcounts~=0);
                end
                
                
            end
            
        else % split
            
            % reallocate, keeping track of the probas for the M-H ratio
            % for this I need the sufficient stats for the 'new' groups in
            % the merge case starting from one single obs in each group
            % (RANDOM SAMPLE ORDER! (Dahl 2003))
            
            n_S(2)=1;
            
            if c_i>sources
                
                n_S(1) = 1; % keeps track of the number of items in each 'new-old' component
                meens(:,1) = training_data(:,ind(1));
                meens(:,2) = training_data(:,ind(2));
                
                sum_s(:,:,1) = yyT(:,:,ind(1));
                sum_s(:,:,2) = yyT(:,:,ind(2));
                
            else
                
                n_S(1) = ns(c_j)+1; % keeps track of the number of items in each 'new-old' component
                meens(:,1) = orgmeans(:,c_j) + (1/n_S(1))*(training_data(:,ind(1))-orgmeans(:,c_j)); % one stays with baseline
                meens(:,2) = training_data(:,ind(2)); % other one is on his own
                
                sum_s(:,:,1) = orgsum_squares(:,:,c_j) + yyT(:,:,ind(1));
                sum_s(:,:,2) = yyT(:,:,ind(2));
                
            end
            
            cmeans = orgmeans(:,c_j);
            csums = orgsum_squares(:,:,c_j);
            cns = ns(c_j);
            clik=1;cprod=1;setlik=1;likelihood=zeros(1,2);
            prob_i=zeros(2,1);
            
            class_id_temp=class_id(:,2);
            class_id_temp(ind(2))=K_plus+1; % ind 2 marks new class
            
            ixxs = find(class_id(:,2)==c_j);
            ixxs(ixxs==ind(1) |ixxs==ind(2))=[];
            ixxs=[ind(1); ind(2); ixxs];
            
            for o = [1 2 randperm(n_j-2)+2]
                k=ixxs(o);
                
                % calculate the combined likelihood
                
                y_k = training_data(:,k);
                
                m_Y = cmeans;
                k_n = k_0+cns;
                mu_n = k_0/(k_n)*mu_0 + cns/(k_n)*m_Y;
                v_n = v_0+cns;
                v = v_n-D+1;
                
                S = (csums - cns*(m_Y*m_Y'));
                zm_Y = m_Y-mu_0;
                lambda_n = lambda_0 + S  + k_0*cns/(k_n)*(zm_Y)*(zm_Y)';
                Sigma = (lambda_n*(k_n+1)/(k_n*v))';
                vd = v+D;
                
                clikelihood = pc_gammaln_by_2(vd) - (pc_gammaln_by_2(v) + d2*pc_log(v) + ...
                    d2*pc_log_pi) - .5*log(det(Sigma))-...
                    (vd/2)*reallog(1+(1/v)*(y_k-mu_n)'*Sigma^-1*(y_k-mu_n));
                
                clik=clik*exp(clikelihood);
                cns=cns+1;
                cmeans = cmeans + (1/cns)*(y_k-cmeans);
                csums = csums + yyT(:,:,k);
                
                
                % calculate individual set likelihoods
                
                if o==1 || o==2
                    
                    for ell = 1:2
                        n = double(n_S(ell)-1);
                        m_Y = orgmeans(:,class_id(ind(ell),2));
                        k_n = k_0+n;
                        mu_n = k_0/(k_n)*mu_0 + n/(k_n)*m_Y;
                        v_n = v_0+n;
                        
                        v = v_n-D+1;
                        mu = mu_n;
                        
                        S = (orgsum_squares(:,:,class_id(ind(ell),2)) - n*(m_Y*m_Y'));
                        zm_Y = m_Y-mu_0;
                        lambda_n = lambda_0 + S  + ...
                            k_0*n/(k_n)*(zm_Y)*(zm_Y)';
                        Sigma = (lambda_n*(k_n+1)/(k_n*(v_n-D+1)))';
                        
                        log_det_Sigma = log(det(Sigma));
                        inv_Sigma = Sigma^-1;
                        log_det_cov(ell) = log_det_Sigma;
                        inv_cov(:,:,ell) = inv_Sigma;
                        
                        vd = v+D;
                        
                        likelihood(ell) = pc_gammaln_by_2(vd) - (pc_gammaln_by_2(v) + d2*pc_log(v) + ...
                            d2*pc_log_pi) - .5*log_det_Sigma-...
                            (vd/2)*reallog(1+(1/v)*(y_k-mu)'*inv_Sigma*(y_k-mu));
                        
                    end
                    
                    likelihood = exp(likelihood);
                    setlik=setlik*likelihood(o);
                    
                    continue
                end
                
                for ell = 1:2
                    n = double(n_S(ell));
                    m_Y = meens(:,ell);
                    mu_n = k_0/(k_0+n)*mu_0 + n/(k_0+n)*m_Y;
                    k_n = k_0+n;
                    v_n = v_0+n;
                    
                    % set up variables for Gelman's formulation of the Student T
                    % distribution
                    v = v_n-D+1;
                    mu = mu_n;
                    
                    S = (sum_s(:,:,ell) - n*(m_Y*m_Y'));
                    zm_Y = m_Y-mu_0;
                    lambda_n = lambda_0 + S  + ...
                        k_0*n/(k_0+n)*(zm_Y)*(zm_Y)';
                    Sigma = (lambda_n*(k_n+1)/(k_n*(v_n-D+1)))';
                    
                    log_det_Sigma = log(det(Sigma));
                    inv_Sigma = Sigma^-1;
                    log_det_cov(ell) = log_det_Sigma;
                    inv_cov(:,:,ell) = inv_Sigma;
                    
                    vd = v+D;
                    
                    likelihood(ell)  = pc_gammaln_by_2(vd) - (pc_gammaln_by_2(v) + d2*pc_log(v) + ...
                        d2*pc_log_pi) - .5*log_det_Sigma-...
                        (vd/2)*reallog(1+(1/v)*(y_k-mu)'*inv_Sigma*(y_k-mu));
                    
                end
                
                m_S=n_S;
                m_S(1)=n_S(1)-ns(c_j);
                
                likelihood = exp(likelihood);
                prob_i(1) = (m_S(1)*likelihood(1))/sum(m_S.*likelihood); % the proba of choosing S_i for individual k
                prob_i(2) = 1-prob_i(1);
                
                if rand<prob_i(1) % S_i is chosen
                    
                    setlik=setlik*likelihood(1);
                    cprod=cprod*prob_i(1);
                    
                    n_S(1) = n_S(1)+1;
                    
                    meens(:,1) = meens(:,1)+ (1/n_S(1))*(y_k-meens(:,1));
                    sum_s(:,:,1) = sum_s(:,:,1) + yyT(:,:,k);
                    
                else % S_j is chosen
                    
                    setlik=setlik*likelihood(2);
                    cprod=cprod*prob_i(2);
                    
                    n_S(2) = n_S(2)+1;
                    class_id_temp(k)=K_plus+1;
                    meens(:,2) = meens(:,2)+ (1/n_S(2))*(y_k-meens(:,2));
                    sum_s(:,:,2) = sum_s(:,:,2) + yyT(:,:,k);
                    
                end
                
            end
            
            
            M_H_prior = exp((gammaln(n_S(1)-ns(c_j))+gammaln(n_S(2)))-gammaln(n_j))*alpha;
            M_H_Lik =setlik/clik;
            M_H_rat = M_H_prior*(M_H_Lik)*(1/cprod);
            
            if rand<M_H_rat && any(class_id_temp~=class_id(:,2)) % accept ?
                %disp('accept split')
                
                % first update suff-stats of new groups
                counts(c_j) = n_S(1)-ns(c_j);
                allcounts(c_j) = n_S(1);
                counts(K_plus+1) = n_S(2);
                allcounts(K_plus+1) = n_S(2);
                
                means(:,c_j) = meens(:,1);
                means(:,K_plus+1) = meens(:,2);
                
                sum_squares(:,:,K_plus+1) = sum_s(:,:,2);
                sum_squares(:,:,c_j) = sum_s(:,:,1);
                
                % update relevant quantities for student -t for c_j and c_i
                
                m_Y = means(:,c_j);
                n=double(allcounts(c_j));
                k_n = k_0+n;
                v_n = v_0+n;
                
                S = (sum_squares(:,:,c_j) - n*(m_Y*m_Y'));
                zm_Y = m_Y-mu_0;
                lambda_n = lambda_0 + S  + ...
                    k_0*n/(k_0+n)*(zm_Y)*(zm_Y)';
                Sigma = (lambda_n*(k_n+1)/(k_n*(v_n-D+1)))';
                
                log_det_cov(c_j) = log(det(Sigma));
                inv_cov(:,:,c_j) = Sigma^-1;
                
                m_Y = means(:,K_plus+1);
                n=double(allcounts(K_plus+1));
                k_n = k_0+n;
                v_n = v_0+n;
                
                S = (sum_squares(:,:,K_plus+1) - n*(m_Y*m_Y'));
                zm_Y = m_Y-mu_0;
                lambda_n = lambda_0 + S  + ...
                    k_0*n/(k_0+n)*(zm_Y)*(zm_Y)';
                Sigma = (lambda_n*(k_n+1)/(k_n*(v_n-D+1)))';
                
                log_det_cov(K_plus+1) = log(det(Sigma));
                inv_cov(:,:,K_plus+1) = Sigma^-1;
                
                K_plus=K_plus+1;
                class_id(:,2)=class_id_temp;
            end
            
        end
        
    end
    
    %% Gibbs sample - adapted from Frank Wood's DPM spike sorter 0.1, Radford Neal's algo 3 for conjugate data
    if sweep<=intro
        class_id(:,2) = class_id(:,1);
    end
    
    for i=1:N
        
        y = training_data(:,i);
        
        old_class_id= class_id(i,2);
         
        counts(old_class_id) = counts(old_class_id) -1;
        allcounts(old_class_id) = allcounts(old_class_id) -1;
        
        if counts(old_class_id)==0 && old_class_id>sources % this only happens for new classes
            % delete the source and compact all data structures
            
            hits = class_id(:,2)>=old_class_id;
            class_id(hits,2) = class_id(hits,2)-1;
            K_plus = K_plus-1;
            
            hits = [1:old_class_id-1 old_class_id+1:(K_plus+1)];
            means(:,1:K_plus) = means(:,hits);
            means(:,K_plus+1) = 0;
            sum_squares(:,:,1:K_plus) = sum_squares(:,:,hits);
            sum_squares(:,:,1+K_plus) = 0;
            counts(1:K_plus) = counts(hits);
            counts(K_plus+1) = 0;
            allcounts(1:K_plus) = allcounts(hits);
            allcounts(K_plus+1) = 0;
            
            log_det_cov(1:K_plus) = log_det_cov(hits);
            log_det_cov(K_plus+1) = 0;
            inv_cov(:,:,1:K_plus) = inv_cov(:,:,hits);
            inv_cov(:,:,K_plus+1) = 0;
            
            
        else
            means(:,old_class_id) = (1/(double(allcounts(old_class_id))))...
                *((double(allcounts(old_class_id))+1)*means(:,old_class_id) - y);
            sum_squares(:,:,old_class_id) = sum_squares(:,:,old_class_id) - yyT(:,:,i);
        end
        
        
        % complete the CRP prior with new table prob.
        priornum=[];
        
        if sweep ~= 1
            priornum(counts(1:K_plus)~=0) = double(counts(counts(1:K_plus)~=0));
            priornum(counts(1:K_plus)==0) = repmat(alpha,sum(counts(1:K_plus)==0),1)/(sum(counts(1:K_plus)==0)+1);
            prior = [priornum';alpha/(sum(counts(1:K_plus)==0)+1)]/(N-1+alpha);
        else
            priornum(counts(1:K_plus)~=0) = double(counts(counts(1:K_plus)~=0));
            priornum(counts(1:K_plus)==0) = repmat(alpha,sum(counts(1:K_plus)==0),1)/(sum(counts(1:K_plus)==0)+1);
            prior = [priornum';alpha/(sum(counts(1:K_plus)==0)+1)]/(i-1+alpha);
        end
        
        likelihood = zeros(length(prior),1);
        
        % as per Radford's Alg. 3 we will compute the posterior predictive
        % probabilities in two scenerios, 1) we will evaluate the
        % likelihood of sitting at all of the existing tables by computing
        % the probability of the datapoint under the posterior predictive
        % distribution with all points sitting at that table considered and
        % 2) we will compute the likelihood of the point under the
        % posterior predictive distribution with no observations
        
        for ell = 1:K_plus
            % get the class ids of the points sitting at table l
            n = double(allcounts(ell));
            %             if n~=0
            m_Y = means(:,ell);
            mu_n = k_0/(k_0+n)*mu_0 + n/(k_0+n)*m_Y;
            k_n = k_0+n;
            v_n = v_0+n;
            
            % set up variables for Gelman's formulation of the Student T
            % distribution
            v = v_n-D+1;
            mu = mu_n;
            
            
            % if old_class_id == ell means that this point used to sit at
            % table ell, all of the sufficient statistics have been updated
            % in sum_squares, counts, and means but that means that we have
            % to recompute log_det_Sigma and inv_Sigma.  if we reseat the
            % particle at its old table then we can put the old
            % log_det_Sigma and inv_Sigma back, otherwise we need to update
            % both the old table and the new table
            if old_class_id ~= 0
                if old_class_id == ell
                    S = (sum_squares(:,:,ell) - n*(m_Y*m_Y'));
                    zm_Y = m_Y-mu_0;
                    lambda_n = lambda_0 + S  + ...
                        k_0*n/(k_0+n)*(zm_Y)*(zm_Y)';
                    Sigma = (lambda_n*(k_n+1)/(k_n*(v_n-D+1)))';
                    
                    old_class_log_det_Sigma = log_det_cov(old_class_id);
                    old_class_inv_Sigma = inv_cov(:,:,old_class_id);
                    
                    log_det_Sigma = log(det(Sigma));
                    lastwarn=[];
                    try in_Sigma = (Sigma)^-1;
                    catch exi
                    end
                    if isempty(lastwarn)
                        inv_Sigma=in_Sigma ;
                    end
                    lastwarn=[];
                    log_det_cov(old_class_id) = log_det_Sigma;
                    inv_cov(:,:,old_class_id) = inv_Sigma;
                else
                    log_det_Sigma = log_det_cov(ell);
                    inv_Sigma = inv_cov(:,:,ell);
                end
            else
                % this case is the first sweep through the data
                S = (sum_squares(:,:,ell) - n*(m_Y*m_Y'));
                zm_Y = m_Y-mu_0;
                lambda_n = lambda_0 + S  + ...
                    k_0*n/(k_0+n)*(zm_Y)*(zm_Y)';
                Sigma = (lambda_n*(k_n+1)/(k_n*(v_n-D+1)))';
                
                log_det_Sigma = log(det(Sigma));
                inv_Sigma = (Sigma)^-1;
                log_det_cov(ell) = log_det_Sigma;
                inv_cov(:,:,ell) = inv_Sigma;
            end
            
            vd = v+D;
            
            % the log likelihood for class ell
            likelihood(ell) = pc_gammaln_by_2(vd) - (pc_gammaln_by_2(v) + d2*pc_log(v) + ...
                d2*pc_log_pi) - .5*log_det_Sigma-...
                (vd/2)*log(1+(1/v)*(y-mu)'*inv_Sigma*(y-mu));
            
        end
        likelihood(K_plus+1) = p_under_prior_alone(i);
        
        likelihood = exp(likelihood-max(likelihood));
        likelihood = likelihood/sum(likelihood);
        
        % compute the posterior over seating assignment for datum i
        posterior = prior.*likelihood; % this is actually a proportionality
        % normalize the posterior
        posterior = posterior/sum(posterior);
        
        % pick the new table
        cdf = cumsum(posterior);
        rn = rand;
        
        new_class_id = find((cdf>rn)==1,1);
        
        %         if isempty(new_class_id)
        %             new_class_id=old_class_id;
        %         end
        
        counts(new_class_id) = counts(new_class_id)+1;
        allcounts(new_class_id) = allcounts(new_class_id)+1;
        means(:,new_class_id) = means(:,new_class_id)+ (1/double(allcounts(new_class_id)))*(y-means(:,new_class_id));
        sum_squares(:,:,new_class_id) = sum_squares(:,:,new_class_id) + yyT(:,:,i);
        
        if new_class_id == K_plus+1
            K_plus = K_plus+1;
        end
        
        if old_class_id == new_class_id
            % we don't need to compute anything new as the point was
            % already sitting at that table and the matrix inverse won't
            % change
            log_det_cov(old_class_id) = old_class_log_det_Sigma;
            inv_cov(:,:,old_class_id) = old_class_inv_Sigma;
        else
            % the point changed tables which means that the matrix inverse
            % sitting in the old_class_id slot is appropriate but that the
            % new table matrix inverse needs to be updated
            n = double(allcounts(new_class_id));
            %             if n~=0
            m_Y = means(:,new_class_id);
            k_n = k_0+n;
            v_n = v_0+n;
            
            % set up variables for Gelman's formulation of the Student T
            % distribution
            S = (sum_squares(:,:,new_class_id) - n*(m_Y*m_Y'));
            zm_Y = m_Y-mu_0;
            lambda_n = lambda_0 + S  + ...
                k_0*n/(k_0+n)*(zm_Y)*(zm_Y)';
            Sigma = (lambda_n*(k_n+1)/(k_n*(v_n-D+1)))';
            
            log_det_cov(new_class_id) = log(det(Sigma));
            inv_cov(:,:,new_class_id) = Sigma^-1;
        end
        
        % record the new table class_id(:,2)
        class_id(i,2) = new_class_id;
        
    end
    
    class_id(:,1) = class_id(:,2);
    
    %% MCMC Alpha update code
    
    K_plus_mix = length(unique(class_id(:,2)));
    
    nu = betarnd(alpha+1,N);
    pis=(a_0+K_plus_mix-1)/(a_0+K_plus_mix-1+N*(b_0-log(nu)));
    alpha = (pis*(randgamma(a_0+K_plus_mix)/(b_0-log(nu))))+((1-pis)*(randgamma(a_0+K_plus_mix-1)/(b_0-log(nu))));
    
    %% random other crap
    if sweep>intro
        muu = zeros(D,K_plus);sums=0;
        invsig = zeros(D,D,K_plus);
        sig = zeros(D,D,K_plus);sumsig=0;
        for k =1:K_plus
            
            m_Y = means(:,k);
            n=double(allcounts(k));
            mu_n = k_0/(k_0+n)*mu_0 + n/(k_0+n)*m_Y;
            
            SS = (sum_squares(:,:,k) - n*(m_Y*m_Y'));
            zm_Y = m_Y-mu_0;
            lambda_n = lambda_0 + SS + k_0*n/(k_0+n)*(zm_Y)*(zm_Y)';
            
            v_n=v_0+n;
           
            try sig_new=iwishrnd(lambda_n,v_n);
            catch ex1
                
                if ~isempty(ex1.message)
                    sig_new = sum_squares(:,:,k)./double(allcounts(k));
                end
            end
            
            lastwarn=[];
            inv(sig_new);
            
            if isempty(lastwarn)
            sig(:,:,k)=sig_new;
            end
            
            % if k==0
            %     sig(:,:,k)=sig_new;
            % end
            
            
            muu(:,k)=mvnrnd(mu_n,sig(:,:,k)/(k_0+n));
            
            invsig(:,:,k)=inv(sig(:,:,k));
            
            sums=sums+invsig(:,:,k)*muu(:,k);
            sumsig=sumsig+invsig(:,:,k);
        end
   
        meansig=inv(sumsig);
        
        mu_0 = randnorm(1,meansig*sums,[],meansig./k_0);
        sums=0;
        
        for k=1:K_plus
            muu(:,k);
            invsig(:,:,k);
            sums = sums+ (muu(:,k)-mu_0)'*invsig(:,:,k)*(muu(:,k)-mu_0);
        end
%        sums
%        mu_0
%        k_0
        k_0 = randgamma((double(K_plus))/2)*((sums)/2);
        
    end
    %% record the current parameters values
    %allcounts
    if mod(sweep,thin)==0
        K_record(sweep/thin) = K_plus;
        K_mix_record(sweep/thin) = K_plus_mix;
        alpha_record(sweep/thin) = alpha;
        k_0s(sweep/thin)=k_0;
        class_ids(:,sweep/thin)=class_id(:,1);
    end
    if(GRAPHICS && mod(sweep,thin)==0)
        figure(1)
        subplot(2,2,1)
        plot(1:thin:sweep,k_0s(1:round(sweep/thin)));
        title('k_0')
        subplot(2,2,4)
        plot(1:thin:sweep,K_record(1:round(sweep/thin)));
        title('K overall');
        subplot(2,2,3)
        plot(1:thin:sweep,K_mix_record(1:round(sweep/thin)));
        title('K mixed sample');
        subplot(2,2,2)
        plot(1:thin:sweep,alpha_record(1:round(sweep/thin)));
        title('gamma');
    end
    time_1_obs = toc;
end